# ---------------------------------------------------------------------------
# text.awk - ログイベントをテキスト出力用に整形する
#
#   入力: 発生時刻(ms) \t レベル \t ログストリーム \t メッセージ(エスケープ済)
#   変数: ERRC / WARNC / INFOC / RESET (ANSI コード。埋め込まない場合は空文字)
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
    header = sprintf("[%s] [%-5s] [%s]", cw_fmt_time(ms), level, stream)

    n = split(msg, lines, "\n")
    if (n == 0) { n = 1; lines[1] = "" }

    print paint(header " " lines[1], code)
    for (i = 2; i <= n; i++) print paint("    " lines[i], code)
}
