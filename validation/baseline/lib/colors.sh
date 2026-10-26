#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# colors.sh - ターミナル向け ANSI カラー出力
# ---------------------------------------------------------------------------

declare -A CW_ANSI=(
    [default]=""
    [reset]=$'\033[0m'
    [bold]=$'\033[1m'
    [dim]=$'\033[2m'
    [black]=$'\033[30m'
    [red]=$'\033[31m'
    [green]=$'\033[32m'
    [yellow]=$'\033[33m'
    [blue]=$'\033[34m'
    [magenta]=$'\033[35m'
    [cyan]=$'\033[36m'
    [white]=$'\033[37m'
    [gray]=$'\033[90m'
    [bright_red]=$'\033[91m'
    [bright_green]=$'\033[92m'
    [bright_yellow]=$'\033[93m'
    [bright_blue]=$'\033[94m'
    [bright_magenta]=$'\033[95m'
    [bright_cyan]=$'\033[96m'
    [bright_white]=$'\033[97m'
)

# カラー出力が有効かどうか (1=有効 / 0=無効)
CW_COLOR_ENABLED=0

# 出力先が ANSI カラーに対応しているか判定する
cw_supports_color() {
    [[ -n ${NO_COLOR:-} ]] && return 1
    [[ -n ${CWLOG_FORCE_COLOR:-} ]] && return 0
    [[ -t 1 ]] || return 1
    [[ ${TERM:-dumb} == dumb ]] && return 1
    return 0
}

# 色コードを取得する (無効時 / 不明な色名は空文字)
cw_code() {
    local name=$1
    [[ $CW_COLOR_ENABLED -eq 1 ]] || return 0
    [[ -z $name || $name == default ]] && return 0
    printf '%s' "${CW_ANSI[$name]:-}"
}

# cw_paint <文字列> <色名> [bold]
cw_paint() {
    local text=$1 color=${2:-default} bold=${3:-}
    if [[ $CW_COLOR_ENABLED -ne 1 ]]; then
        printf '%s' "$text"
        return 0
    fi
    local prefix=""
    [[ -n $bold ]] && prefix="${CW_ANSI[bold]}"
    if [[ -n $color && $color != default ]]; then
        prefix+="${CW_ANSI[$color]:-}"
    fi
    if [[ -z $prefix ]]; then
        printf '%s' "$text"
    else
        printf '%s%s%s' "$prefix" "$text" "${CW_ANSI[reset]}"
    fi
}

cw_c_error() { cw_paint "$1" bright_red; }
cw_c_warn()  { cw_paint "$1" bright_yellow; }
cw_c_ok()    { cw_paint "$1" bright_green; }
cw_c_info()  { cw_paint "$1" bright_cyan; }
cw_c_dim()   { cw_paint "$1" gray; }

# 改行付きで出力するショートハンド
cw_say()       { printf '%s\n' "$*"; }
cw_say_err()   { printf '%s\n' "$(cw_c_error "$*")" >&2; }
cw_say_warn()  { printf '%s\n' "$(cw_c_warn "$*")"; }
cw_say_ok()    { printf '%s\n' "$(cw_c_ok "$*")"; }
cw_say_info()  { printf '%s\n' "$(cw_c_info "$*")"; }
cw_say_dim()   { printf '%s\n' "$(cw_c_dim "$*")"; }
