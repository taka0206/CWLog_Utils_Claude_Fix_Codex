#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config.sh - 設定の読み込みとマージ
#
# 優先順位 (後勝ち):
#   デフォルト  <  設定ファイル (.conf / .json)  <  環境変数  <  コマンドライン引数
#
# 設定ファイルは 2 形式:
#   *.conf : bash の変数代入 (source される)。配列も指定可。
#   *.json : jq で読み込む。トップレベルはセクション辞書。
# ---------------------------------------------------------------------------

# --- 設定キー一覧 (スカラー) ------------------------------------------------
CW_CONFIG_KEYS=(
    aws_profile aws_region
    auth_login_command auth_timeout auth_skip
    switchback_mode switchback_script switchback_shell switchback_timeout
    switchback_retry switchback_codecommit_role_pattern switchback_isolated
    groups_max_items groups_regex
    events_engine events_limit events_hours events_order
    events_latest_stream events_stream_scan_limit
    events_chunk_max_seconds events_max_chunks events_timezone
    colors_enabled colors_error_color colors_warn_color colors_info_color
    export_dir export_text_ansi
    export_excel_error_fill export_excel_warn_fill
    export_excel_info_fill export_excel_header_fill
)

# --- 設定キー一覧 (配列) ----------------------------------------------------
CW_CONFIG_ARRAY_KEYS=(
    switchback_args
    colors_error_patterns colors_warn_patterns colors_exclude_patterns
)

CW_CONFIG_FILENAMES=(cwlog.conf .cwlog.conf cwlog.json .cwlog.json)

# 読み込んだ設定ファイルのパス
CW_CONFIG_PATH=""

# ---------------------------------------------------------------------------
# デフォルト値
# ---------------------------------------------------------------------------
cw_config_defaults() {
    # --- AWS 接続 ---
    CFG_aws_profile=""
    CFG_aws_region="ap-northeast-1"

    # --- 事前認証 (aws login --remote) チェック ---
    CFG_auth_login_command="aws login --remote"
    CFG_auth_timeout=15
    CFG_auth_skip=0

    # --- 権限不足時のスイッチバック ---
    # off / warn / auto
    CFG_switchback_mode="warn"
    CFG_switchback_script=""
    CFG_switchback_args=()
    CFG_switchback_shell="bash"
    CFG_switchback_timeout=120
    CFG_switchback_retry=1
    CFG_switchback_codecommit_role_pattern="codecommit"
    # 1 にすると別プロセスのシェルで source して環境変数だけを取り込む
    CFG_switchback_isolated=0

    # --- ロググループ一覧 ---
    CFG_groups_max_items=500
    CFG_groups_regex=0

    # --- ログイベント取得 ---
    CFG_events_engine="filter"
    CFG_events_limit=1000
    CFG_events_hours=24
    # asc = 昇順 (古い順, 既定) / desc = 降順 (新しい順)
    CFG_events_order="asc"
    # 1 にすると最新のログストリーム 1 本だけを対象にする (既定)
    CFG_events_latest_stream=1
    # 最新ログストリームを探すときに走査するログストリームの最大本数
    CFG_events_stream_scan_limit=50
    CFG_events_chunk_max_seconds=21600
    CFG_events_max_chunks=240
    CFG_events_timezone="Asia/Tokyo"

    # --- 行のカラーリング判定 (gawk の拡張 ERE。\y = 単語境界) ---
    CFG_colors_enabled=1
    CFG_colors_error_patterns=(
        '\y(ERROR|ERR|FATAL|CRITICAL|CRIT|SEVERE|PANIC|EMERG|ALERT)\y'
        '\y(Exception|Traceback|StackTrace|Stack trace)\y'
        '^[[:space:]]*Caused by:'
        '\y(AccessDenied|Unauthorized|Forbidden|Timeout|TimedOut)\y'
        '(エラー|失敗しました|異常終了|致命的)'
    )
    CFG_colors_warn_patterns=(
        '\y(WARN|WARNING|CAUTION|NOTICE|DEPRECATED)\y'
        '\y(retry|retrying|fallback|throttl[[:alnum:]_]*)\y'
        '(警告|注意|リトライ)'
    )
    CFG_colors_exclude_patterns=(
        '\yerrors?[[:space:]]*[=:][[:space:]]*(0|null|""|\[\]|false|none)\y'
        '\ywarn(ing)?s?[[:space:]]*[=:][[:space:]]*(0|null|\[\]|false|none)\y'
    )
    CFG_colors_error_color="bright_red"
    CFG_colors_warn_color="bright_yellow"
    CFG_colors_info_color="default"

    # --- 出力 ---
    CFG_export_dir="./output"
    CFG_export_text_ansi=0
    CFG_export_excel_error_fill="FFF4CCCC"
    CFG_export_excel_warn_fill="FFFFF2CC"
    CFG_export_excel_info_fill="FFFFFFFF"
    CFG_export_excel_header_fill="FF305496"
}

# ---------------------------------------------------------------------------
# 設定ファイルの探索
#   探索順: 明示指定 -> カレント -> スクリプト配置元 -> ~/.config/cwlog -> ~
# ---------------------------------------------------------------------------
cw_config_discover() {
    local explicit=${1:-}
    if [[ -n $explicit ]]; then
        local path=${explicit/#\~/$HOME}
        if [[ ! -f $path ]]; then
            cw_say_err "設定エラー: 設定ファイルが見つかりません: $path"
            return 1
        fi
        printf '%s' "$path"
        return 0
    fi
    local dir name
    for dir in "$PWD" "$CW_ROOT" "$HOME/.config/cwlog" "$HOME"; do
        [[ -d $dir ]] || continue
        for name in "${CW_CONFIG_FILENAMES[@]}"; do
            if [[ -f $dir/$name ]]; then
                printf '%s' "$dir/$name"
                return 0
            fi
        done
    done
    return 0
}

# ---------------------------------------------------------------------------
# 設定ファイルの読み込み
# ---------------------------------------------------------------------------
cw_config_load_file() {
    local path=$1
    case $path in
        *.json) cw_config_load_json "$path" ;;
        *)      cw_config_load_conf "$path" ;;
    esac
}

# *.conf: bash としてそのまま source し、既知のキーだけを取り込む
cw_config_load_conf() {
    local path=$1 key
    # shellcheck disable=SC1090
    if ! source "$path"; then
        cw_say_err "設定エラー: 設定ファイルの読み込みに失敗しました: $path"
        return 1
    fi
    for key in "${CW_CONFIG_KEYS[@]}"; do
        if [[ -v $key ]]; then
            printf -v "CFG_$key" '%s' "${!key}"
            unset "$key"
        fi
    done
    for key in "${CW_CONFIG_ARRAY_KEYS[@]}"; do
        if declare -p "$key" >/dev/null 2>&1; then
            eval "CFG_$key=(\"\${$key[@]}\")"
            unset "$key"
        fi
    done
    return 0
}

# *.json: jq で `section_key=値` 形式へ変換して取り込む
cw_config_load_json() {
    local path=$1 lines key
    if ! command -v jq >/dev/null 2>&1; then
        cw_say_err "設定エラー: JSON 設定ファイルの読み込みには jq が必要です: $path"
        cw_say_err "  dnf install -y jq を実行するか、.conf 形式の設定ファイルを使用してください。"
        return 1
    fi
    if ! lines=$(jq -r "$CW_CONFIG_JQ" "$path" 2>&1); then
        cw_say_err "設定エラー: JSON 設定ファイルを解釈できません: $path"
        cw_say_err "  $lines"
        return 1
    fi

    local -A known=()
    for key in "${CW_CONFIG_KEYS[@]}" "${CW_CONFIG_ARRAY_KEYS[@]}"; do
        known[$key]=1
    done

    local line name
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        name=${line%%=*}
        [[ -n ${known[$name]:-} ]] || continue
        eval "CFG_$line"
    done <<< "$lines"
    return 0
}

# JSON -> `section_key=値` 変換用の jq プログラム
# 配列は bash の配列リテラル、null は空文字、真偽値は 1/0 にする。
read -r -d '' CW_CONFIG_JQ <<'CW_JQ_EOF' || :
to_entries[]
| .key as $s
| select((.value | type) == "object")
| .value
| to_entries[]
| "\($s)_\(.key)=" +
  ( if   (.value | type) == "array"   then "(" + ((.value | map(@sh)) | join(" ")) + ")"
    elif (.value | type) == "null"    then "\"\""
    elif (.value | type) == "boolean" then (if .value then "1" else "0" end)
    else (.value | tostring | @sh)
    end )
CW_JQ_EOF

# ---------------------------------------------------------------------------
# 環境変数の反映
# ---------------------------------------------------------------------------
cw_config_apply_env() {
    [[ -n ${AWS_PROFILE:-}             ]] && CFG_aws_profile=$AWS_PROFILE
    [[ -n ${CWLOG_PROFILE:-}           ]] && CFG_aws_profile=$CWLOG_PROFILE
    [[ -n ${AWS_DEFAULT_REGION:-}      ]] && CFG_aws_region=$AWS_DEFAULT_REGION
    [[ -n ${AWS_REGION:-}              ]] && CFG_aws_region=$AWS_REGION
    [[ -n ${CWLOG_REGION:-}            ]] && CFG_aws_region=$CWLOG_REGION
    [[ -n ${CWLOG_LOGIN_COMMAND:-}     ]] && CFG_auth_login_command=$CWLOG_LOGIN_COMMAND
    [[ -n ${CWLOG_SWITCHBACK_MODE:-}   ]] && CFG_switchback_mode=$CWLOG_SWITCHBACK_MODE
    [[ -n ${CWLOG_SWITCHBACK_SCRIPT:-} ]] && CFG_switchback_script=$CWLOG_SWITCHBACK_SCRIPT
    [[ -n ${CWLOG_SWITCHBACK_SHELL:-}  ]] && CFG_switchback_shell=$CWLOG_SWITCHBACK_SHELL
    [[ -n ${CWLOG_OUTPUT_DIR:-}        ]] && CFG_export_dir=$CWLOG_OUTPUT_DIR
    [[ -n ${CWLOG_TIMEZONE:-}          ]] && CFG_events_timezone=$CWLOG_TIMEZONE
    return 0
}

# ---------------------------------------------------------------------------
# デフォルト + 設定ファイル + 環境変数
# ---------------------------------------------------------------------------
cw_config_load() {
    local explicit=${1:-} path
    cw_config_defaults
    if ! path=$(cw_config_discover "$explicit"); then
        return 1
    fi
    if [[ -n $path ]]; then
        CW_CONFIG_PATH=$path
        cw_config_load_file "$path" || return 1
    fi
    cw_config_apply_env
    return 0
}

# 真偽値の判定 (1/true/yes/on を真とする)
cw_is_true() {
    case ${1,,} in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# 表示タイムゾーンを適用してコマンドを実行する
#   events_timezone が空のときは TZ を設定しない (システム既定を使う)
#   ※ TZ="" は UTC 扱いになるため、空のまま渡してはいけない
cw_tzrun() {
    if [[ -n ${CFG_events_timezone:-} ]]; then
        TZ="$CFG_events_timezone" "$@"
    else
        "$@"
    fi
}
