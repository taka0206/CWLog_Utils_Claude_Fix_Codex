#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# auth.sh - 事前認証チェックと、権限不足時のスイッチバック
#
#   1. `aws login --remote` 等による事前認証が済んでいるかを STS で確認する。
#      未認証なら警告メッセージを出して終了する (終了コード 2)。
#   2. CloudWatch Logs への操作権限があるかを確認する。
#      権限が無い (CodeCommit 用ロール等のままである) 場合、
#        - mode=warn : スイッチバックを促すメッセージを出して終了 (終了コード 3)
#        - mode=auto : 別チーム提供のシェルを source して自動スイッチバック
# ---------------------------------------------------------------------------

# 未認証 (資格情報そのものが無い / 失効) と判断するメッセージ
CW_RE_UNAUTHENTICATED='Unable to locate credentials|ExpiredToken|RequestExpired|TokenRefreshRequired|InvalidClientTokenId|NoCredentialProviders|could not be found|SSO ?[Ss]ession|sso.*[Tt]oken|Token has expired|refresh failed|InvalidGrantException|UnauthorizedSSOToken'
# 権限不足 (スイッチバック対象) と判断するメッセージ
CW_RE_NO_PERMISSION='AccessDenied|AccessDeniedException|UnauthorizedOperation|AuthorizationError|AuthFailure|UnrecognizedClientException|MissingAuthenticationToken|SignatureDoesNotMatch|is not authorized to perform'

# source 実行後に環境変数を切り出すためのマーカー
CW_ENV_MARKER="__CWLOG_ENV_DUMP__"

# 直近の aws CLI の標準エラー出力
CW_AWS_STDERR=""
# aws CLI がメジャーバージョン 2 か (1 = v2)
CW_AWS_V2=0

# 認証済み ID
CW_ID_ACCOUNT=""
CW_ID_ARN=""
CW_ID_USERID=""

# ---------------------------------------------------------------------------
# 前提コマンドの確認
# ---------------------------------------------------------------------------
cw_require_commands() {
    local missing=() cmd
    for cmd in aws jq awk sort date mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! awk --version 2>/dev/null | head -1 | grep -qi 'gnu awk'; then
        missing+=("gawk (GNU awk)")
    fi
    if ((${#missing[@]} > 0)); then
        cw_say_err "[エラー] 次のコマンドが見つかりません: ${missing[*]}"
        cw_say_err "         dnf install -y jq gawk coreutils を実行し、AWS CLI を導入してください。"
        return 1
    fi
    local version
    version=$(aws --version 2>&1)
    case $version in
        aws-cli/2.*) CW_AWS_V2=1 ;;
        *)           CW_AWS_V2=0 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# aws CLI 呼び出しラッパ
#   cw_aws_run <出力ファイル> <aws のサブコマンド...>
#   標準エラーは CW_AWS_STDERR へ格納する。
# ---------------------------------------------------------------------------
cw_aws_run() {
    local outfile=$1
    shift
    local -a cmd=(aws)
    [[ -n $CFG_aws_region ]] && cmd+=(--region "$CFG_aws_region")
    # スイッチバック後は環境変数の資格情報を優先するため、
    # 環境変数に一時キーがある場合はプロファイル指定を外す
    if [[ -n $CFG_aws_profile && -z ${AWS_ACCESS_KEY_ID:-} ]]; then
        cmd+=(--profile "$CFG_aws_profile")
    fi
    ((CW_AWS_V2 == 1)) && cmd+=(--no-cli-pager)
    cmd+=(--output json "$@")

    local errfile="$CW_TMPDIR/aws.err"
    local rc=0
    AWS_PAGER="" "${cmd[@]}" >"$outfile" 2>"$errfile" || rc=$?
    CW_AWS_STDERR=$(<"$errfile")
    return $rc
}

# 直近のエラー出力が正規表現に一致するか
cw_aws_err_matches() {
    printf '%s' "$CW_AWS_STDERR" | grep -qE "$1"
}

# エラー出力の要約 (先頭の意味のある 1 行)
cw_aws_err_summary() {
    printf '%s' "$CW_AWS_STDERR" \
        | grep -v '^[[:space:]]*$' \
        | tail -1 \
        | cut -c1-300
}

# ---------------------------------------------------------------------------
# 1. 事前認証チェック
# ---------------------------------------------------------------------------
cw_check_authenticated() {
    local outfile="$CW_TMPDIR/identity.json"
    local timeout=${CFG_auth_timeout:-15}
    local rc=0

    cw_aws_run "$outfile" sts get-caller-identity \
        --cli-connect-timeout "$timeout" --cli-read-timeout "$timeout" || rc=$?

    if ((rc != 0)); then
        if cw_aws_err_matches "$CW_RE_UNAUTHENTICATED" \
            || cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
            cw_unauthenticated_message "$(cw_aws_err_summary)" >&2
            return 2
        fi
        printf '%s %s\n' "$(cw_c_error '[認証エラー]')" \
            "STS の呼び出しに失敗しました: $(cw_aws_err_summary)" >&2
        return 2
    fi

    CW_ID_ACCOUNT=$(jq -r '.Account // ""' "$outfile")
    CW_ID_ARN=$(jq -r '.Arn // ""' "$outfile")
    CW_ID_USERID=$(jq -r '.UserId // ""' "$outfile")
    return 0
}

cw_unauthenticated_message() {
    local detail=$1
    local bar
    bar=$(printf '=%.0s' {1..72})
    printf '\n'
    printf '%s\n' "$(cw_c_error "$bar")"
    printf '%s\n' "$(cw_c_error '  [認証エラー] AWS への事前認証が完了していません。')"
    printf '%s\n' "$(cw_c_error "$bar")"
    printf '\n'
    printf '%s\n' '  先に下記のコマンドを実行して認証を行ってから、再度実行してください。'
    printf '\n'
    printf '      %s\n' "$(cw_paint "$CFG_auth_login_command" bright_cyan bold)"
    printf '\n'
    printf '%s\n' "$(cw_c_dim "  詳細: $detail")"
    printf '\n'
}

# 認証済み ID の表示
cw_print_identity() {
    printf '%s%s\n' "$(cw_c_ok '[認証OK] ')" \
        "アカウント: $(cw_paint "$CW_ID_ACCOUNT" bright_white bold)"
    printf '         ID      : %s\n' "$CW_ID_ARN"
    printf '         リージョン: %s\n' "$CFG_aws_region"
    [[ -n $CFG_aws_profile ]] && printf '         プロファイル: %s\n' "$CFG_aws_profile"
    return 0
}

# ---------------------------------------------------------------------------
# 2. 権限チェック
# ---------------------------------------------------------------------------
# 戻り値: 0=権限あり / 1=権限なし / 2=その他のエラー
# 詳細メッセージは CW_PERMISSION_DETAIL へ格納する。
CW_PERMISSION_DETAIL=""
cw_has_logs_permission() {
    local outfile="$CW_TMPDIR/perm.json"
    local rc=0
    cw_aws_run "$outfile" logs describe-log-groups --max-items 1 || rc=$?
    if ((rc == 0)); then
        CW_PERMISSION_DETAIL="ok"
        return 0
    fi
    CW_PERMISSION_DETAIL=$(cw_aws_err_summary)
    if cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
        return 1
    fi
    return 2
}

# 現在のロールが CodeCommit 用ロールらしいか (メッセージ補助)
cw_looks_like_codecommit_role() {
    [[ -n $CFG_switchback_codecommit_role_pattern ]] || return 1
    printf '%s' "$CW_ID_ARN" | grep -qEi "$CFG_switchback_codecommit_role_pattern"
}

cw_switchback_required_message() {
    local detail=$1
    local script=${CFG_switchback_script:-}
    [[ -n $script ]] || script='<switchback_script 未設定>'
    local bar
    bar=$(printf '=%.0s' {1..72})
    printf '\n'
    printf '%s\n' "$(cw_c_warn "$bar")"
    printf '%s\n' "$(cw_c_warn '  [権限エラー] 現在の権限では AWS (CloudWatch Logs) を操作できません。')"
    printf '%s\n' "$(cw_c_warn "$bar")"
    printf '\n'
    printf '  現在の ID : %s\n' "$CW_ID_ARN"
    printf '  アカウント: %s\n' "$CW_ID_ACCOUNT"
    if cw_looks_like_codecommit_role; then
        printf '%s\n' "$(cw_c_dim '  ※ CodeCommit 用ロールのままである可能性があります。')"
    fi
    printf '\n'
    printf '%s\n' '  スイッチバックしてから再実行してください。'
    printf '\n'
    printf '      %s\n' "$(cw_paint "source $script" bright_cyan bold)"
    printf '\n'
    printf '%s\n' "$(cw_c_dim '  自動でスイッチバックする場合は --switchback-mode auto を指定してください。')"
    printf '%s\n' "$(cw_c_dim "  詳細: $detail")"
    printf '\n'
}

# ---------------------------------------------------------------------------
# 3. スイッチバック
# ---------------------------------------------------------------------------
# スイッチバック用シェルのパスを解決する (結果は CW_SWITCHBACK_PATH)
CW_SWITCHBACK_PATH=""
cw_resolve_switchback_script() {
    local raw=${CFG_switchback_script:-}
    if [[ -z $raw ]]; then
        cw_say_err "スイッチバック用シェルのパスが未設定です。"
        cw_say_err "  --switchback-script <PATH> オプション、設定ファイルの switchback_script、"
        cw_say_err "  または環境変数 CWLOG_SWITCHBACK_SCRIPT で指定してください。"
        return 1
    fi
    local path=${raw/#\~/$HOME}
    if [[ ! -f $path ]]; then
        cw_say_err "スイッチバック用シェルが見つかりません: $path"
        return 1
    fi
    CW_SWITCHBACK_PATH=$path
    return 0
}

# 現在のシェルで直接 source する (このプロセスの環境変数が切り替わる)
cw_source_in_place() {
    local script=$1
    shift
    local saved rc=0
    # source 先が set -e / set -u を残しても影響しないよう退避・復元する
    saved=$(set +o)
    set +eu
    # shellcheck disable=SC1090
    . "$script" "$@" || rc=$?
    eval "$saved" >/dev/null 2>&1
    return $rc
}

# 別プロセスのシェルで source し、AWS_* 環境変数だけを取り込む
cw_source_isolated() {
    local script=$1
    shift
    local shell=${CFG_switchback_shell:-bash}
    local timeout=${CFG_switchback_timeout:-120}
    local outfile="$CW_TMPDIR/switchback.out"
    local errfile="$CW_TMPDIR/switchback.err"
    local snippet rc=0

    snippet='set +u; . "$1" "${@:2}"; __cw_rc=$?; printf "\n%s\n" "'"$CW_ENV_MARKER"'"; env; exit $__cw_rc'

    if ! command -v "$shell" >/dev/null 2>&1; then
        cw_say_err "シェル '$shell' が見つかりません。switchback_shell の設定を確認してください。"
        return 1
    fi

    timeout "$timeout" "$shell" -lc "$snippet" cwlog-switchback "$script" "$@" \
        >"$outfile" 2>"$errfile" || rc=$?

    if ((rc == 124)); then
        cw_say_err "スイッチバックがタイムアウトしました (${timeout}秒): $script"
        return 1
    fi

    # マーカーより前がスクリプトの出力、後ろが環境変数一覧
    local marker_line
    marker_line=$(grep -n "^${CW_ENV_MARKER}\$" "$outfile" | tail -1 | cut -d: -f1)
    if [[ -z $marker_line ]]; then
        sed 's/^/  | /' "$outfile" | while IFS= read -r l; do cw_say_dim "$l"; done
        cw_say_err "スイッチバック後の環境変数を取得できませんでした。"
        cw_say_err "  シェル '$shell' で source 実行が可能か確認してください。"
        return 1
    fi

    head -n "$((marker_line - 1))" "$outfile" | grep -v '^[[:space:]]*$' \
        | while IFS= read -r l; do cw_say_dim "  | $l"; done
    grep -v '^[[:space:]]*$' "$errfile" \
        | while IFS= read -r l; do cw_say_dim "  | $l" >&2; done

    if ((rc != 0)); then
        cw_say_err "スイッチバック用シェルが異常終了しました (exit=$rc): $script"
        return 1
    fi

    # AWS_* だけを取り込む
    local line name value
    CW_IMPORTED_VARS=()
    while IFS= read -r line; do
        [[ $line == AWS_*=* ]] || continue
        name=${line%%=*}
        value=${line#*=}
        if [[ ${!name-} != "$value" ]]; then
            export "$name=$value"
            CW_IMPORTED_VARS+=("$name")
        fi
    done < <(tail -n "+$((marker_line + 1))" "$outfile")
    return 0
}

CW_IMPORTED_VARS=()

# スイッチバックを実行する
cw_switch_back() {
    cw_resolve_switchback_script || return 1
    local script=$CW_SWITCHBACK_PATH
    local -a args=()
    ((${#CFG_switchback_args[@]} > 0)) && args=("${CFG_switchback_args[@]}")

    cw_say_info "[スイッチバック] $script を source して権限を切り替えます..."

    local before
    before=$(env | grep '^AWS_' | sort)

    if cw_is_true "${CFG_switchback_isolated:-0}"; then
        cw_source_isolated "$script" ${args[@]+"${args[@]}"} || return 1
    else
        local outfile="$CW_TMPDIR/switchback.out"
        local rc=0
        # 出力は握りつぶさずインデントして見せる
        cw_source_in_place "$script" ${args[@]+"${args[@]}"} >"$outfile" 2>&1 || rc=$?
        grep -v '^[[:space:]]*$' "$outfile" 2>/dev/null \
            | while IFS= read -r l; do cw_say_dim "  | $l"; done
        if ((rc != 0)); then
            cw_say_err "スイッチバック用シェルが異常終了しました (exit=$rc): $script"
            return 1
        fi
        # 変化した AWS_* を記録する
        CW_IMPORTED_VARS=()
        local name
        while IFS= read -r name; do
            [[ -n $name ]] && CW_IMPORTED_VARS+=("$name")
        done < <(comm -13 <(printf '%s\n' "$before") <(env | grep '^AWS_' | sort) \
                    | cut -d= -f1 | sort -u)
    fi

    if ((${#CW_IMPORTED_VARS[@]} == 0)); then
        cw_say_warn "[警告] スイッチバックにより変化した AWS 関連の環境変数はありませんでした。"
    else
        local joined
        joined=$(printf '%s\n' "${CW_IMPORTED_VARS[@]}" | sort -u | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')
        cw_say_ok "[スイッチバック] 完了しました (取り込み: $joined)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 権限を確保する (必要ならスイッチバック)
#   戻り値: 0=OK / 1=一般エラー / 3=権限不足
# ---------------------------------------------------------------------------
cw_ensure_permissions() {
    local mode=${CFG_switchback_mode,,}
    [[ $mode == off ]] && return 0

    local rc=0
    cw_has_logs_permission || rc=$?
    if ((rc == 0)); then
        return 0
    fi
    if ((rc == 2)); then
        cw_say_err "[エラー] CloudWatch Logs への接続に失敗しました: $CW_PERMISSION_DETAIL"
        return 1
    fi

    if [[ $mode != auto ]]; then
        cw_switchback_required_message "$CW_PERMISSION_DETAIL" >&2
        return 3
    fi

    # --- 自動スイッチバック ---
    local retry=${CFG_switchback_retry:-1}
    ((retry < 1)) && retry=1
    local attempt
    for ((attempt = 1; attempt <= retry; attempt++)); do
        cw_switch_back || return 1
        cw_check_authenticated || return 2
        rc=0
        cw_has_logs_permission || rc=$?
        if ((rc == 0)); then
            cw_say_ok "[スイッチバック] 権限を確認しました: $CW_ID_ARN"
            return 0
        fi
        cw_say_warn "[警告] スイッチバック後も権限が不足しています (試行 ${attempt}/${retry}): $CW_PERMISSION_DETAIL"
    done

    cw_switchback_required_message "$CW_PERMISSION_DETAIL" >&2
    cw_say_err "  自動スイッチバックを実行しましたが権限を取得できませんでした。"
    return 3
}
