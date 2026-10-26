# ---------------------------------------------------------------------------
# render.awk - ログイベントを画面へレベル別に色付けして表示する
#
#   入力: 発生時刻(ms) \t レベル \t ログストリーム \t メッセージ(エスケープ済)
#   変数: ERRC / WARNC / INFOC / DIMC / RESET (ANSI コード。無効時は空文字)
# ---------------------------------------------------------------------------

function paint(text, code) {
    if (code == "" || RESET == "") return text
    return code text RESET
}

BEGIN { FS = "\t" }

{
    ms = $1
    level = $2
    stream = ($3 == "") ? "-" : $3
    msg = cw_unesc($4)

    code = (level == "ERROR") ? ERRC : ((level == "WARN") ? WARNC : INFOC)
    stamp = cw_fmt_time(ms)

    n = split(msg, lines, "\n")
    if (n == 0) { n = 1; lines[1] = "" }

    print paint(sprintf("%s  %-5s  %s", stamp, level, lines[1]), code)

    pad = sprintf("%*s", length(stamp) + 9, "")
    for (i = 2; i <= n; i++) print paint(pad lines[i], code)

    if (n > 1 || level != "INFO") print paint("    └ stream: " stream, DIMC)
}
