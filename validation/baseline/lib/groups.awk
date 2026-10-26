# ---------------------------------------------------------------------------
# groups.awk - ロググループ一覧を番号付きで表示する
#
#   入力: ロググループ名 \t 保存バイト数 \t 保持日数
#   変数: OFFSET (0 始まりの表示開始位置) / PAGE (1 ページ件数。0 なら全件)
#         HEADC / DIMC / WARNC / RESET (ANSI コード)
#
#   日本語の見出しがあるため、桁揃えは表示幅 (全角=2桁) で行う。
# ---------------------------------------------------------------------------

function paint(text, code) {
    if (code == "" || RESET == "") return text
    return code text RESET
}

BEGIN { FS = "\t"; total = 0 }

{
    total++
    name[total] = $1
    size[total] = $2
    keep[total] = $3
}

END {
    from = OFFSET + 1
    to = (PAGE + 0 > 0) ? OFFSET + PAGE : total
    if (to > total) to = total

    if (from > to) {
        print paint("  該当するロググループはありません。", WARNC)
        exit
    }

    width = 20
    for (i = from; i <= to; i++) if (cw_dwidth(name[i]) > width) width = cw_dwidth(name[i])
    width += 2
    if (width > 80) width = 80

    print paint("  " cw_pad_left("No", 4) "  " cw_pad_right("ロググループ名", width) \
                " " cw_pad_left("サイズ", 10) "  " cw_pad_left("保持", 8), HEADC)
    line = ""
    for (i = 0; i < width + 28; i++) line = line "-"
    print paint("  " line, DIMC)

    for (i = from; i <= to; i++) {
        label = name[i]
        if (cw_dwidth(label) > width) label = substr(label, 1, width - 3) "..."
        print "  " cw_pad_left(i "", 4) "  " cw_pad_right(label, width) \
              " " cw_pad_left(cw_human_size(size[i]), 10) \
              "  " cw_pad_left(cw_human_retention(keep[i]), 8)
    }
}
