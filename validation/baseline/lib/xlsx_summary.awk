# ---------------------------------------------------------------------------
# xlsx_summary.awk - サマリシート (sheet1.xml) の行を生成する
#
#   入力: 項目名 \t 値
#   変数: NERR / NWARN / NINFO (レベル別件数)
# ---------------------------------------------------------------------------

BEGIN { FS = "\t"; row = 0 }

function cell_str(ref, style, value) {
    printf "<c r=\"%s\" s=\"%d\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%s</t></is></c>",
           ref, style, cw_esc_xml(value)
}

function cell_num(ref, style, value) {
    printf "<c r=\"%s\" s=\"%d\"><v>%s</v></c>", ref, style, value
}

BEGIN {
    printf "<row r=\"1\">"
    cell_str("A1", 1, "CloudWatch Logs エクスポート")
    printf "</row>\n"
    row = 2
}

{
    row++
    printf "<row r=\"%d\">", row
    cell_str("A" row, 2, $1)
    cell_str("B" row, 3, $2)
    printf "</row>\n"
}

END {
    row += 2
    printf "<row r=\"%d\">", row
    cell_str("A" row, 2, "レベル")
    cell_str("B" row, 2, "件数")
    printf "</row>\n"

    split("ERROR WARN INFO", levels, " ")
    counts[1] = NERR + 0; counts[2] = NWARN + 0; counts[3] = NINFO + 0
    for (i = 1; i <= 3; i++) {
        row++
        printf "<row r=\"%d\">", row
        cell_str("A" row, i + 4, levels[i])
        cell_num("B" row, 3, counts[i])
        printf "</row>\n"
    }
}
