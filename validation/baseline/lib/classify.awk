# ---------------------------------------------------------------------------
# classify.awk - 共通関数群 (gawk -f classify.awk -f <本体>.awk で読み込む)
#
#   * ログ行のレベル判定 (ERROR / WARN / INFO)
#   * TSV エスケープ (\n \t \r \\) の復元
#   * epoch ミリ秒の整形
#   * XML エスケープ
#
# 判定パターンはファイルから読み込む。1 行 1 パターンで、
#   E<TAB>正規表現   エラー判定
#   W<TAB>正規表現   警告判定
#   X<TAB>正規表現   除外 (判定前にマスクする)
# 正規表現は gawk の拡張 ERE (\y = 単語境界)。大文字小文字は区別しない。
# ---------------------------------------------------------------------------

function cw_load_patterns(file,    line, kind, pat) {
    CW_NE = 0; CW_NW = 0; CW_NX = 0
    if (file == "") return
    while ((getline line < file) > 0) {
        if (length(line) < 3) continue
        kind = substr(line, 1, 1)
        pat = substr(line, 3)
        if (pat == "") continue
        if (kind == "E")      CW_EPAT[++CW_NE] = pat
        else if (kind == "W") CW_WPAT[++CW_NW] = pat
        else if (kind == "X") CW_XPAT[++CW_NX] = pat
    }
    close(file)
}

# jq の @tsv が施したエスケープを元に戻す
function cw_unesc(s,    out, i, c, d, L) {
    if (index(s, "\\") == 0) return s
    L = length(s)
    out = ""
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < L) {
            d = substr(s, i + 1, 1)
            if (d == "n")       { out = out "\n"; i++ }
            else if (d == "t")  { out = out "\t"; i++ }
            else if (d == "r")  { out = out "\r"; i++ }
            else if (d == "\\") { out = out "\\"; i++ }
            else                { out = out c }
        } else {
            out = out c
        }
    }
    return out
}

# 1 行のレベルを判定する
function cw_classify_line(line,    i, masked) {
    if (line ~ /^[[:space:]]*$/) return "INFO"
    masked = line
    # 除外パターンに該当する箇所は判定対象から取り除く (errors=0 等の誤検知回避)
    for (i = 1; i <= CW_NX; i++) gsub(CW_XPAT[i], " ", masked)
    for (i = 1; i <= CW_NE; i++) if (masked ~ CW_EPAT[i]) return "ERROR"
    for (i = 1; i <= CW_NW; i++) if (masked ~ CW_WPAT[i]) return "WARN"
    return "INFO"
}

# 複数行メッセージ全体のレベル (最も重いレベル) を返す
function cw_classify(msg,    n, i, parts, lv, worst) {
    worst = "INFO"
    n = split(msg, parts, "\n")
    if (n == 0) return "INFO"
    for (i = 1; i <= n; i++) {
        lv = cw_classify_line(parts[i])
        if (lv == "ERROR") return "ERROR"
        if (lv == "WARN") worst = "WARN"
    }
    return worst
}

# epoch ミリ秒 -> 'YYYY-MM-DD HH:MM:SS.mmm' (TZ 環境変数に従う)
function cw_fmt_time(ms,    sec, rest) {
    sec = int(ms / 1000)
    rest = ms - sec * 1000
    return strftime("%Y-%m-%d %H:%M:%S", sec) sprintf(".%03d", rest)
}

# epoch ミリ秒 -> 任意書式
function cw_fmt_time_fmt(ms, fmt,    sec) {
    sec = int(ms / 1000)
    return strftime(fmt, sec)
}

# XML エスケープ + Excel に書けない制御文字の除去
function cw_esc_xml(s,    t) {
    t = s
    gsub(/&/, "\\&amp;", t)
    gsub(/</, "\\&lt;", t)
    gsub(/>/, "\\&gt;", t)
    gsub(/"/, "\\&quot;", t)
    gsub(/\047/, "\\&apos;", t)
    gsub(/[\001-\010\013\014\016-\037]/, " ", t)
    return t
}

# 保存バイト数を人が読める形へ (-1 は不明)
function cw_human_size(bytes,    v, i, units) {
    if (bytes < 0) return "-"
    split("B KB MB GB TB PB", units, " ")
    v = bytes + 0
    for (i = 1; i <= 6; i++) {
        if (v < 1024 || i == 6) {
            if (i == 1) return sprintf("%.0fB", v)
            return sprintf("%.1f%s", v, units[i])
        }
        v = v / 1024
    }
    return bytes ""
}

# 保持日数を人が読める形へ (0 は無期限)
function cw_human_retention(days) {
    if (days + 0 <= 0) return "無期限"
    return days "日"
}

# 表示幅を数えるための文字表を用意する
#   ロケールにより gawk が文字単位・バイト単位のどちらで動くかが変わるため、
#   最初の呼び出しで判定して両方に対応する。
#   ※ バイト値の範囲を正規表現の [ ] で書くと、ja_JP.UTF-8 等のロケールでは
#      「無効な照合文字です」となり gawk が異常終了するため、
#      正規表現ではなく文字表を index() で引いて判定する。
function cw_width_init(    i) {
    CW_MB = (length("あ") == 1) ? 1 : 0
    CW_ASCII = ""
    for (i = 1; i < 128; i++) CW_ASCII = CW_ASCII sprintf("%c", i)
    CW_CONT = ""   # UTF-8 の継続バイト   (0x80-0xBF)
    CW_WIDE = ""   # 3/4 バイト文字の先頭 (0xE0-0xFF)
    if (CW_MB) return
    for (i = 128; i <= 191; i++) CW_CONT = CW_CONT sprintf("%c", i)
    for (i = 224; i <= 255; i++) CW_WIDE = CW_WIDE sprintf("%c", i)
}

# 表示幅 (全角文字を 2 桁として数える)
function cw_dwidth(s,    i, n, c, w) {
    if (CW_ASCII == "") cw_width_init()
    n = length(s)
    w = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (index(CW_ASCII, c) > 0) { w += 1; continue }   # ASCII
        if (CW_MB) { w += 2; continue }                    # 文字単位: 非 ASCII は全角扱い
        if (index(CW_CONT, c) > 0) continue                # UTF-8 の継続バイト
        if (index(CW_WIDE, c) > 0) { w += 2; continue }    # 3/4 バイト文字 (CJK など)
        w += 1                                             # 2 バイト文字 (ラテン等)
    }
    return w
}

# 表示幅を揃えて左詰め / 右詰めする
function cw_pad_right(s, width,    n, p) {
    n = width - cw_dwidth(s)
    p = ""
    while (n-- > 0) p = p " "
    return s p
}

function cw_pad_left(s, width,    n, p) {
    n = width - cw_dwidth(s)
    p = ""
    while (n-- > 0) p = p " "
    return p s
}
