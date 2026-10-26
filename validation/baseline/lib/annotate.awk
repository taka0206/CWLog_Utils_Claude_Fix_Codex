# ---------------------------------------------------------------------------
# annotate.awk - ログイベントへレベルを付与し、--level で絞り込む
#
#   入力: 発生時刻(ms) \t ログストリーム \t メッセージ(エスケープ済)
#   出力: 発生時刻(ms) \t レベル \t ログストリーム \t メッセージ(エスケープ済)
#   件数: COUNTFILE へ "ERROR件数 \t WARN件数 \t INFO件数" を書き出す
# ---------------------------------------------------------------------------

BEGIN {
    FS = "\t"; OFS = "\t"
    IGNORECASE = 1
    cw_load_patterns(PATFILE)
    nerr = 0; nwarn = 0; ninfo = 0
}

{
    level = cw_classify(cw_unesc($3))

    if (LEVEL == "error" && level != "ERROR") next
    if (LEVEL == "warn"  && level != "WARN")  next
    if (LEVEL == "warn+" && level == "INFO")  next

    if (level == "ERROR")     nerr++
    else if (level == "WARN") nwarn++
    else                      ninfo++

    print $1, level, $2, $3
}

END {
    printf "%d\t%d\t%d\n", nerr, nwarn, ninfo > COUNTFILE
    close(COUNTFILE)
}
