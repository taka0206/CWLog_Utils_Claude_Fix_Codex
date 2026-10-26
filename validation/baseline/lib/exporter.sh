#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# exporter.sh - ログのテキスト / Excel 出力
#
# Excel (.xlsx) は OpenXML (XML の ZIP アーカイブ) を直接組み立てる。
# 圧縮には zip または bsdtar を使用する。
# ---------------------------------------------------------------------------

# ロググループ名などをファイル名に使える形へ変換する
cw_safe_slug() {
    local text=$1 slug
    slug=$(printf '%s' "$text" | sed -e 's/[^0-9A-Za-z._-]\+/_/g' -e 's/^_\+//' -e 's/_\+$//')
    slug=${slug:0:60}
    slug=$(printf '%s' "$slug" | sed -e 's/_\+$//')
    [[ -z $slug ]] && slug="log"
    printf '%s' "$slug"
}

# 出力先パスを決定する (未指定なら自動命名)
#   cw_build_output_path <出力ディレクトリ> <ロググループ> <拡張子> [明示パス]
cw_build_output_path() {
    local out_dir=$1 group=$2 ext=$3 explicit=${4:-}
    local path
    if [[ -n $explicit ]]; then
        path=${explicit/#\~/$HOME}
        # 拡張子が無い場合のみ補う
        local base=${path##*/}
        [[ $base != *.* ]] && path="$path$ext"
        mkdir -p "$(dirname "$path")" || return 1
        printf '%s' "$path"
        return 0
    fi
    local dir=${out_dir/#\~/$HOME}
    mkdir -p "$dir" || return 1
    printf '%s/cwlog_%s_%s%s' "$dir" "$(cw_safe_slug "$group")" "$(date '+%Y%m%d_%H%M%S')" "$ext"
}

# ---------------------------------------------------------------------------
# テキスト出力
#   cw_export_text <イベントTSV> <出力パス> <メタTSV> <ANSI埋め込み?>
# ---------------------------------------------------------------------------
cw_export_text() {
    local events=$1 path=$2 meta=$3 with_ansi=$4
    local bar
    bar=$(printf '=%.0s' {1..100})

    local errc="" warnc="" infoc="" reset=""
    if cw_is_true "$with_ansi"; then
        errc=${CW_ANSI[${CFG_colors_error_color}]:-}
        warnc=${CW_ANSI[${CFG_colors_warn_color}]:-}
        infoc=${CW_ANSI[${CFG_colors_info_color}]:-}
        reset=${CW_ANSI[reset]}
    fi

    {
        printf '%s\n' "$bar"
        printf '%s\n' "CloudWatch Logs エクスポート"
        printf '%s\n' "$bar"
        awk -f "$CW_ROOT/lib/classify.awk" -f "$CW_ROOT/lib/meta.awk" "$meta"
        printf '%s\n' "$bar"
        printf '\n'
        cw_tzrun awk \
            -f "$CW_ROOT/lib/classify.awk" -f "$CW_ROOT/lib/text.awk" \
            -v ERRC="$errc" -v WARNC="$warnc" -v INFOC="$infoc" -v RESET="$reset" \
            "$events"
    } > "$path" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Excel 出力
#   cw_export_excel <イベントTSV> <出力パス> <メタTSV> <ERROR件数> <WARN件数> <INFO件数>
# ---------------------------------------------------------------------------
cw_export_excel() {
    local events=$1 path=$2 meta=$3 nerr=$4 nwarn=$5 ninfo=$6
    local work="$CW_TMPDIR/xlsx"

    local archiver=""
    if command -v zip >/dev/null 2>&1; then
        archiver=zip
    elif command -v bsdtar >/dev/null 2>&1; then
        archiver=bsdtar
    else
        cw_say_err "[エラー] Excel 出力には zip コマンドが必要です (dnf install -y zip)。"
        cw_say_err "         テキスト出力 (--text) は zip 無しでも利用できます。"
        return 1
    fi

    rm -rf "$work"
    mkdir -p "$work/_rels" "$work/xl/_rels" "$work/xl/worksheets" || return 1

    local rows tz_label
    rows=$(wc -l < "$events")
    rows=$((rows))
    local last_row=$((rows + 1))
    ((last_row < 2)) && last_row=2
    tz_label=$(cw_tzrun date '+%Z')

    cw_xlsx_content_types > "$work/[Content_Types].xml"
    cw_xlsx_root_rels     > "$work/_rels/.rels"
    cw_xlsx_workbook      > "$work/xl/workbook.xml"
    cw_xlsx_workbook_rels > "$work/xl/_rels/workbook.xml.rels"
    cw_xlsx_styles        > "$work/xl/styles.xml"

    # --- サマリシート ---
    {
        cw_xml_header
        printf '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        printf '<cols><col min="1" max="1" width="22" customWidth="1"/>'
        printf '<col min="2" max="2" width="72" customWidth="1"/></cols>'
        printf '<sheetData>\n'
        awk -f "$CW_ROOT/lib/classify.awk" -f "$CW_ROOT/lib/xlsx_summary.awk" \
            -v NERR="$nerr" -v NWARN="$nwarn" -v NINFO="$ninfo" "$meta"
        printf '</sheetData></worksheet>\n'
    } > "$work/xl/worksheets/sheet1.xml" || return 1

    # --- ログシート ---
    {
        cw_xml_header
        printf '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        printf '<sheetViews><sheetView tabSelected="1" workbookViewId="0">'
        printf '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        printf '</sheetView></sheetViews>'
        printf '<sheetFormatPr defaultRowHeight="15"/>'
        printf '<cols>'
        printf '<col min="1" max="1" width="7" customWidth="1"/>'
        printf '<col min="2" max="2" width="22" customWidth="1"/>'
        printf '<col min="3" max="3" width="9" customWidth="1"/>'
        printf '<col min="4" max="4" width="42" customWidth="1"/>'
        printf '<col min="5" max="5" width="120" customWidth="1"/>'
        printf '</cols>'
        printf '<sheetData>\n'
        cw_xlsx_header_row "$tz_label"
        cw_tzrun awk \
            -f "$CW_ROOT/lib/classify.awk" -f "$CW_ROOT/lib/xlsx.awk" "$events"
        printf '</sheetData>'
        printf '<autoFilter ref="A1:E%d"/>' "$last_row"
        printf '</worksheet>\n'
    } > "$work/xl/worksheets/sheet2.xml" || return 1

    # --- ZIP 化 ---
    rm -f "$path"
    local abs=$path
    [[ $abs == /* ]] || abs="$PWD/$path"
    local rc=0
    if [[ $archiver == zip ]]; then
        ( cd "$work" && printf '%s\n' \
            '[Content_Types].xml' '_rels/.rels' 'xl/workbook.xml' \
            'xl/_rels/workbook.xml.rels' 'xl/styles.xml' \
            'xl/worksheets/sheet1.xml' 'xl/worksheets/sheet2.xml' \
            | zip -q -X -@ "$abs" ) || rc=$?
    else
        ( cd "$work" && bsdtar --format zip -cf "$abs" \
            '[Content_Types].xml' '_rels' 'xl' ) || rc=$?
    fi
    if ((rc != 0)); then
        cw_say_err "[エラー] Excel ファイルの作成に失敗しました (exit=$rc)"
        return 1
    fi
    return 0
}

cw_xml_header() {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
}

cw_xlsx_content_types() {
    cw_xml_header
    cat <<'CW_XML'
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>
CW_XML
}

cw_xlsx_root_rels() {
    cw_xml_header
    cat <<'CW_XML'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
CW_XML
}

cw_xlsx_workbook() {
    cw_xml_header
    cat <<'CW_XML'
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="サマリ" sheetId="1" r:id="rId1"/>
<sheet name="ログ" sheetId="2" r:id="rId2"/>
</sheets>
</workbook>
CW_XML
}

cw_xlsx_workbook_rels() {
    cw_xml_header
    cat <<'CW_XML'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
CW_XML
}

# レベル別の塗り分け・フォントを定義する
cw_xlsx_styles() {
    local ef=${CFG_export_excel_error_fill:-FFF4CCCC}
    local wf=${CFG_export_excel_warn_fill:-FFFFF2CC}
    local nf=${CFG_export_excel_info_fill:-FFFFFFFF}
    local hf=${CFG_export_excel_header_fill:-FF305496}

    cw_xml_header
    printf '%s' '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'

    printf '%s' '<fonts count="8">'
    printf '%s' '<font><sz val="11"/><color rgb="FF333333"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><b/><sz val="13"/><color rgb="FF000000"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><b/><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><b/><sz val="9"/><color rgb="FF9C0006"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><sz val="9"/><color rgb="FF9C6500"/><name val="Meiryo UI"/></font>'
    printf '%s' '<font><sz val="9"/><color rgb="FF333333"/><name val="Meiryo UI"/></font>'
    printf '%s' '</fonts>'

    printf '%s' '<fills count="6">'
    printf '%s' '<fill><patternFill patternType="none"/></fill>'
    printf '%s' '<fill><patternFill patternType="gray125"/></fill>'
    printf '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/></patternFill></fill>' "$ef"
    printf '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/></patternFill></fill>' "$wf"
    printf '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/></patternFill></fill>' "$nf"
    printf '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/></patternFill></fill>' "$hf"
    printf '%s' '</fills>'

    printf '%s' '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>'
    printf '%s' '<border><left style="thin"><color rgb="FFD9D9D9"/></left>'
    printf '%s' '<right style="thin"><color rgb="FFD9D9D9"/></right>'
    printf '%s' '<top style="thin"><color rgb="FFD9D9D9"/></top>'
    printf '%s' '<bottom style="thin"><color rgb="FFD9D9D9"/></bottom><diagonal/></border></borders>'

    printf '%s' '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'

    printf '%s' '<cellXfs count="14">'
    # 0: 既定 / 1: タイトル / 2: 見出し / 3: 値
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="1" fillId="0" borderId="0" applyFont="1"/>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="2" fillId="0" borderId="0" applyFont="1"/>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="3" fillId="0" borderId="0" applyFont="1"/>'
    # 4: ヘッダ
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="4" fillId="5" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    # 5-7: レベル別 (基本)
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="5" fillId="2" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="6" fillId="3" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="7" fillId="4" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>'
    # 8-10: レベル別 (折り返し)
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="5" fillId="2" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="6" fillId="3" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="7" fillId="4" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
    # 11-13: レベル別 (中央寄せ)
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="5" fillId="2" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="6" fillId="3" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>'
    printf '%s' '<xf xfId="0" numFmtId="0" fontId="7" fillId="4" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>'
    printf '%s' '</cellXfs>'

    printf '%s' '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    printf '%s\n' '</styleSheet>'
}

# ログシートの見出し行
cw_xlsx_header_row() {
    local tz_label=$1
    local -a titles=("No" "日時 ($tz_label)" "レベル" "ログストリーム" "メッセージ")
    local cols=(A B C D E)
    printf '<row r="1">'
    local i
    for i in 0 1 2 3 4; do
        printf '<c r="%s1" s="4" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' \
            "${cols[$i]}" "${titles[$i]}"
    done
    printf '</row>\n'
}
