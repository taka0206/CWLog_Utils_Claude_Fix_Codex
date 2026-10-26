# ---------------------------------------------------------------------------
# xlsx.awk - ログシート (sheet2.xml) の行を生成する
#
#   入力: 発生時刻(ms) \t レベル \t ログストリーム \t メッセージ(エスケープ済)
#   出力: <row> 要素の並び (1 行目のヘッダは呼び出し側で出力する)
#
#   スタイル ID:
#     基本 (日時 / ストリーム) ERROR=5 WARN=6 INFO=7
#     折り返し (メッセージ)    ERROR=8 WARN=9 INFO=10
#     中央寄せ (No / レベル)   ERROR=11 WARN=12 INFO=13
# ---------------------------------------------------------------------------

BEGIN {
    FS = "\t"
    EXCEL_MAX_CELL = 32767
    no = 0
}

function base_style(level) {
    return (level == "ERROR") ? 5 : ((level == "WARN") ? 6 : 7)
}

function cell_str(ref, style, value) {
    printf "<c r=\"%s\" s=\"%d\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%s</t></is></c>",
           ref, style, cw_esc_xml(value)
}

function cell_num(ref, style, value) {
    printf "<c r=\"%s\" s=\"%d\"><v>%s</v></c>", ref, style, value
}

{
    no++
    row = no + 1
    level = $2
    stream = ($3 == "") ? "-" : $3
    msg = cw_unesc($4)

    if (length(msg) > EXCEL_MAX_CELL) {
        msg = substr(msg, 1, EXCEL_MAX_CELL - 20) "...(切り詰め)"
    }

    b = base_style(level)

    printf "<row r=\"%d\">", row
    cell_num("A" row, b + 6, no)
    cell_str("B" row, b, cw_fmt_time($1))
    cell_str("C" row, b + 6, level)
    cell_str("D" row, b, stream)
    cell_str("E" row, b + 3, msg)
    printf "</row>\n"
}
