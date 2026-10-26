#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cwlog.sh - cwlog 起動ラッパー
#
# 使い方:
#   source ./cwlog.sh [オプション...]     # 推奨: スイッチバックが現在のシェルに残る
#   ./cwlog.sh [オプション...]            # 通常実行 (スイッチバックはプロセス内のみ)
#
# `source` で呼び出した場合、--switchback-mode auto / --switchback-now 指定時に
# スイッチバック用シェルを *このシェル自身* で source するため、
# スクリプト終了後も切り替わった権限が維持されます。
# ---------------------------------------------------------------------------

# --- sourced か実行かを判定 ------------------------------------------------
__cwlog_sourced=0
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    __cwlog_sourced=1
elif [ -n "${ZSH_EVAL_CONTEXT:-}" ] && case "$ZSH_EVAL_CONTEXT" in *:file) true;; *) false;; esac; then
    __cwlog_sourced=1
fi

__cwlog_script_dir() {
    local src="${BASH_SOURCE[0]:-$0}"
    cd "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

# 設定ファイルから switchback の設定だけを先読みする (サブシェルで評価)
__cwlog_peek_config() {
    local dir name path key
    key=$1
    for dir in "$PWD" "$(__cwlog_script_dir)" "$HOME/.config/cwlog" "$HOME"; do
        [ -d "$dir" ] || continue
        for name in cwlog.conf .cwlog.conf cwlog.json .cwlog.json; do
            path="$dir/$name"
            [ -f "$path" ] || continue
            case "$path" in
                *.json)
                    command -v jq >/dev/null 2>&1 || return 0
                    jq -r --arg k "$key" '
                        (.switchback // {}) | .[($k | ltrimstr("switchback_"))] // "" | tostring
                    ' "$path" 2>/dev/null
                    ;;
                *)
                    bash -c '. "$1" >/dev/null 2>&1; eval "printf %s \"\${$2-}\""' \
                        _ "$path" "$key" 2>/dev/null
                    ;;
            esac
            return 0
        done
    done
    return 0
}

__cwlog_run() {
    local script_dir
    script_dir="$(__cwlog_script_dir)"

    if [ ! -x "$script_dir/cwlog" ]; then
        echo "[エラー] cwlog 本体が見つかりません: $script_dir/cwlog" >&2
        return 1
    fi

    # --- 引数からスイッチバック関連を先読み ---
    local sb_script="${CWLOG_SWITCHBACK_SCRIPT:-}"
    local sb_mode="${CWLOG_SWITCHBACK_MODE:-}"
    local sb_now=0
    local prev=""
    local arg
    for arg in "$@"; do
        case "$prev" in
            --switchback-script) sb_script="$arg" ;;
            --switchback-mode)   sb_mode="$arg" ;;
        esac
        case "$arg" in
            --switchback-script=*) sb_script="${arg#*=}" ;;
            --switchback-mode=*)   sb_mode="${arg#*=}" ;;
            --switchback-now)      sb_now=1 ;;
        esac
        prev="$arg"
    done
    [ -z "$sb_script" ] && sb_script="$(__cwlog_peek_config switchback_script)"
    [ -z "$sb_mode" ] && sb_mode="$(__cwlog_peek_config switchback_mode)"

    # --- sourced 実行時は、このシェル自身でスイッチバックしておく ---
    if [ "$__cwlog_sourced" -eq 1 ] && [ -n "$sb_script" ]; then
        if [ "$sb_now" -eq 1 ] || [ "$sb_mode" = "auto" ]; then
            local expanded="${sb_script/#\~/$HOME}"
            if [ -f "$expanded" ]; then
                echo "[cwlog.sh] スイッチバック用シェルを source します: $expanded"
                # shellcheck disable=SC1090
                . "$expanded" ${CWLOG_SWITCHBACK_ARGS:-}
                local rc=$?
                if [ $rc -ne 0 ]; then
                    echo "[cwlog.sh][警告] スイッチバック用シェルが異常終了しました (exit=$rc)" >&2
                fi
            else
                echo "[cwlog.sh][警告] スイッチバック用シェルが見つかりません: $expanded" >&2
            fi
        fi
    fi

    "$script_dir/cwlog" "$@"
}

__cwlog_run "$@"
__cwlog_rc=$?

if [ "$__cwlog_sourced" -eq 1 ]; then
    unset -f __cwlog_run __cwlog_script_dir __cwlog_peek_config
    unset __cwlog_sourced
    return $__cwlog_rc
else
    exit $__cwlog_rc
fi
