from pathlib import Path
import hashlib
import subprocess

workspace = Path(__file__).resolve().parent.parent
repo = workspace / "CWLog_Utils_Claude"
files = ["cwlog", "lib/config.sh", "lib/logs.sh"]
base = {f: subprocess.check_output(["git", "show", "HEAD:" + f], cwd=repo).decode("utf-8")
        for f in files}
fixed = {f: (repo / f).read_text(encoding="utf-8") for f in files}
tick, fence, dollar = chr(96), chr(96) * 3, chr(36)
edits = []


def block(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


def add(file, old, new, purpose):
    assert base[file].count(old) == 1
    assert fixed[file].count(new) == 1
    old_line = base[file][:base[file].index(old)].count("\n") + 1
    new_line = fixed[file][:fixed[file].index(new)].count("\n") + 1
    edits.append((file, old, new, purpose, old_line, new_line))


add("lib/config.sh", '    CFG_events_timezone="Asia/Tokyo"\n',
    block(fixed["lib/config.sh"], '    CFG_events_timezone="Asia/Tokyo"\n',
          '    CFG_events_message_timezone=""\n'),
    "本文日時の既定の抽出形式とタイムゾーンを追加する。")
add("lib/config.sh", "    events_chunk_max_seconds events_max_chunks events_timezone\n",
    "    events_chunk_max_seconds events_max_chunks events_timezone\n"
    "    events_message_time_regex events_message_timezone\n",
    "設定の許可リストへ2項目を登録する。これがないと設定ファイルに書いても反映されない。")
engine = "    local engine=" + dollar + "{CFG_events_engine:-filter}\n"
add("cwlog", engine, block(fixed["cwlog"], engine, "    fi\n"),
    "期間指定時のエンジンをfilterにそろえ、画面とExcelサマリにも実際のエンジン名を記録する。")
insights = "# --- insights エンジン ------------------------------------------------------\n"
add("lib/logs.sh", insights,
    block(fixed["lib/logs.sh"],
          "# --- 本文時刻による期間検索 (--start / --end 指定時) --------------------------\n", insights),
    "本文日時で期間判定する関数をInsights処理の直前へ追加する。")
add("lib/logs.sh",
    block(base["lib/logs.sh"], "    local page_size=$remaining\n", "            return 0\n        fi\n"),
    block(fixed["lib/logs.sh"], "    local page_size=$remaining\n", "            return 0\n        fi\n"),
    "本文検索用のremaining=0ではAPIの時刻と総取得件数を制限しない。JSON処理のエラーも返す。")
condition = "    if [[ -n " + dollar + "{ARG_start:-} || -n " + dollar + "{ARG_end:-} ]]; then\n"
add("lib/logs.sh",
    block(base["lib/logs.sh"], "    if [[ $engine == insights ]]; then\n", "    ((rc != 0)) && return $rc\n"),
    block(fixed["lib/logs.sh"], condition, "    ((rc != 0)) && return $rc\n"),
    "期間指定を本文検索へ分岐し、本文日時で絞り込んだ後にイベント時刻が新しいN件を選ぶ。")
add("lib/logs.sh",
    block(base["lib/logs.sh"], "    # イベントを持ち、かつ指定期間と重なる最初のストリームを採用する\n", '    \' "$out"\n'),
    block(fixed["lib/logs.sh"], "    # 本文時刻で検索するときは、イベント時刻でストリームを除外しない。\n", '    \' "$out"\n'),
    "明示的な--latest-stream指定時も、本文の期間をイベント時刻へ誤適用してストリームを除外しない。")
top = "# する場合は、DescribeLogStreams で 1 本に絞ってから取得する。\n"
add("lib/logs.sh", top, top +
    "# --start / --end 指定時は FilterLogEvents で全期間を取得し、本文時刻で\n"
    "# 絞り込んでから上限件数を適用する (cw_fetch_via_message_time)。\n",
    "任意：冒頭の説明コメントを新しい動作に合わせる。実行結果には影響しない。")

replayed = dict(base)
for file, old, new, *_ in edits:
    assert replayed[file].count(old) == 1
    replayed[file] = replayed[file].replace(old, new, 1)
assert replayed == fixed, "Manual replacements do not reproduce the implementation."
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
regex = next(line.strip().removeprefix("CFG_") for line in fixed["lib/config.sh"].splitlines()
             if line.strip().startswith("CFG_events_message_time_regex="))
out = []


def paragraph(text):
    out.append(text.strip() + "\n\n")


def code(text, language="bash"):
    out.append(fence + language + "\n" + text.rstrip() + "\n" + fence + "\n\n")


paragraph(f"""**CloudWatch Logs 本文日時による期間検索：閉域網での手修正手順**

**1. 対象版と反映ファイル**

対象は [ProjectRubyRing/CWLog_Utils_Claude](https://github.com/ProjectRubyRing/CWLog_Utils_Claude) の
main、コミット {tick}{commit}{tick} です。
「変更前の行」はこの版の行番号です。現場の版が異なる場合は、行番号だけで置き換えず、
掲載した変更前コードと関数名で位置を特定してください。

本体の修正対象は **3ファイル** です。Pythonや新しいパッケージは本番環境に追加しません。

| ファイル | 役割 |
|---|---|
| {tick}lib/config.sh{tick} | 本文日時の抽出形式・タイムゾーンの設定 |
| {tick}cwlog{tick} | 取得エンジンの切り替えと検索方法の案内 |
| {tick}lib/logs.sh{tick} | 全候補取得、本文日時の判定、判定後の件数制限 |

{tick}cwlog.sample.conf{tick} と {tick}README.md{tick} は説明用です。
{tick}tests/message_time_test.sh{tick} は確認用で、本番動作には必要ありません。
独自形式を指定する場合は、使用中の設定ファイルにも後述の2項目を追加・変更します。
{tick}cwlog.sh{tick}、{tick}lib/xlsx.awk{tick}、{tick}lib/exporter.sh{tick} の修正は不要です。

**2. 原因と修正の考え方**

元の {tick}lib/logs.sh{tick} の235～237行では、指定期間をAPIの
{tick}--start-time / --end-time{tick} に渡し、{tick}--max-items{tick} で件数を打ち切っています。
この時間条件はイベントの {tick}timestamp{tick} に適用されます。
[AWS FilterLogEvents仕様](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_FilterLogEvents.html)

指定が10:00～11:00、本文が10:30、イベント時刻が12:00のログは、
出力直前の絞り込みだけを変更しても取得できません。
本文日時とイベント時刻のずれの最大値が不明なため、保持されている全期間の候補を取得し、
本文日時で期間判定してから件数上限を適用します。
元の時刻に固定で数時間を足し引きする方法は採用していません。

**3. 修正後の動作**

| 項目 | 動作 |
|---|---|
| 本文時刻検索を使う条件 | {tick}--start{tick} または {tick}--end{tick} の指定 |
| {tick}--hours{tick} のみ | 既存のイベント時刻による取得 |
| 期間の境界 | {tick}開始 <= 本文日時 <= 終了{tick}。ミリ秒より下を切り捨て |
| 本文日時の抽出 | 正規表現の第1括弧で日時全体を取り出す |
| 複数の日時 | 最初の一致を使用。特定フィールドに絞る例は後述 |
| 複数行のメッセージ | 1イベント全体を1件として判定し、本文全体を出力 |
| 日時なし・解析不能 | 除外して件数を警告。イベント時刻を代用しない |
| 取得エンジン | 期間指定時はfilter。insights指定時も通知して切り替える |
| 必要な取得権限 | {tick}logs:FilterLogEvents{tick} |
| {tick}--pattern{tick} | CloudWatchフィルタ構文として渡す |
| {tick}--limit{tick} | 本文で絞り込んだ後、イベント時刻が新しい側からN件を選ぶ |
| Excelの「日時」列・並び順 | 元のイベント時刻 {tick}@timestamp{tick} を使用 |
| 画面・テキスト・Excel | 同じ検索結果を使用 |
| 対象ストリーム | 原則全ストリーム。--latest-streamを明示した場合は最新1本 |

通常のinsights取得ではパターンを部分一致として扱いますが、切り替え後はCloudWatchフィルタ構文です。
特殊記号を含む既存パターンは確認してください。
保持量に応じて通信量、API呼び出し、AWS CLIのメモリ、一時ディスク、日時解析時間が増えます。
{tick}--limit{tick} を小さくしても取得量は減りません。
{tick}--pattern{tick} や {tick}--latest-stream{tick} を使うと、その条件に合うログだけが対象になります。
保持期間を過ぎたログや、検索後に到着したログは対象外です。

**4. バックアップ**

以下はREADME記載の **RHEL / Bash環境** 用のコマンドです。
{tick}cwlog{tick} があるディレクトリから実行します。WindowsのPowerShell用ではありません。""")
code('''backup_dir=$(mktemp -d ./cwlog-before-message-time.XXXXXXXX) || exit 1
mkdir -p "$backup_dir/lib"
cp -p -- cwlog "$backup_dir/cwlog"
cp -p -- lib/config.sh "$backup_dir/lib/config.sh"
cp -p -- lib/logs.sh "$backup_dir/lib/logs.sh"
if [[ -f cwlog.conf ]]; then
    cp -p -- cwlog.conf "$backup_dir/cwlog.conf"
fi
printf 'バックアップ先: %s\\n' "$backup_dir"''')
paragraph(f"""{tick}--config{tick} で別のファイルを使う場合は、その設定ファイルもバックアップします。
既存の設定ファイル全体をサンプルで上書きせず、必要な2項目だけ追加・変更してください。
保存形式は **UTF-8、BOMなし、LF改行** です。
半角の引用符、バックスラッシュ、インデント、行末のバックスラッシュを保ってください。

**5. 手修正する場所**

同じファイルでは下の位置から先に修正する順序にしています。
これにより、これから編集する上側の「変更前の行番号」がずれにくくなります。
各手順の「変更前」ブロック全体を「変更後」ブロック全体に置き換えます。
既存の前後の行や、同じ関数名を二重に残さないでください。

| 手順 | ファイル | 変更前の行 | 変更後の行 | 内容 |
|---|---|---|---|---|""")
for i, (file, old, new, purpose, a, b) in enumerate(edits, 1):
    out.append(f"| 5-{i} | {tick}{file}{tick} | {a}～{a + old.count(chr(10)) - 1} | "
               f"{b}～{b + new.count(chr(10)) - 1} | {purpose} |\n")
out.append("\n")
for i, (file, old, new, purpose, a, b) in enumerate(edits, 1):
    paragraph(f"**5-{i}. {tick}{file}{tick}**\n\n{purpose}\n\n変更前：{a}～{a + old.count(chr(10)) - 1}行。")
    code(old)
    paragraph(f"変更後：修正済みファイルでは{b}～{b + new.count(chr(10)) - 1}行。")
    code(new)
paragraph("""**6. 日時の形式・タイムゾーンの指定**

日付がYYYY-MM-DDまたはYYYY/MM/DDで、時分秒を含む一般的な形式なら追加した既定値で動きます。
次は本文が日本時間の例です。使用中のcwlog.confへ追記するか、同じキーの行を修正します。""")
code(regex + '\nevents_message_timezone="Asia/Tokyo"')
paragraph(f"""| 設定 | 意味 |
|---|---|
| {tick}events_message_time_regex{tick} | Bash拡張正規表現。第1括弧に年・月・日・時・分・秒と必要なら小数秒・タイムゾーンを含める |
| {tick}events_message_timezone{tick} | タイムゾーンのない本文の解釈。日本時間はAsia/Tokyo、UTCはUTC |
| 本文タイムゾーンが空 | --timezone / events_timezoneを使う。それも空ならシステム設定 |

元の {tick}events_timezone{tick} は、開始・終了の指定と出力表示に使います。
「本文はUTC、開始・終了は日本時間」の場合は次の設定にします。""")
code('events_timezone="Asia/Tokyo"\nevents_message_timezone="UTC"')
paragraph(f"""この設定では、日本時間10:00～11:00の検索で本文の01:00～02:00 UTCを取得します。
本文に {tick}Z{tick} や {tick}+09:00{tick} があれば、その情報を本文タイムゾーン設定より優先します。

| 本文中の日時例 | 解釈 |
|---|---|
| 2026-10-26 10:15:30 | 秒まで。タイムゾーンは設定値 |
| 2026-10-26 10:15:30.123 | 小数秒あり |
| 2026/10/26 10:15:30,123 | 日付のスラッシュ、小数点のカンマを正規化 |
| 2026-10-26T01:15:30Z | UTC |
| 2026-10-26T10:15:30+09:00 | 数値オフセット |
| 2026-10-26T10:15:30+0900 | コロンなしの数値オフセット |

形式を変えるときは正規表現を変更します。
抽出文字列のスラッシュをハイフン、最初のカンマをピリオドに変え、GNU {tick}date -d{tick} で解析します。
任意のstrptime書式を指定する実装ではありません。GNU dateが解釈できる絶対日時を抽出してください。
時刻だけを取り出すとGNU dateが当日の日付を補うため、年・月・日まで含めてください。
[GNU date入力仕様](https://www.gnu.org/software/coreutils/manual/html_node/Date-input-formats.html)

本文に複数の日付があり、JSONのeventTimeだけを使う場合の例：""")
code('''events_message_time_regex='"eventTime"[[:space:]]*:[[:space:]]*"([^"]+)"'
events_message_timezone="Asia/Tokyo"''')
code('{"receivedAt":"2026-10-26T12:00:00+09:00","eventTime":"2026-10-26T10:30:00+09:00","message":"処理開始"}', "json")
paragraph(f"""この例はeventTimeの10:30で判定します。抽出は正規表現であり、完全なJSON構文解析ではありません。
フィールド名をメッセージ文字列内にも含むログでは、実際の本文に合わせて確認してください。
正規表現は {tick}\\d{tick} や {tick}(?:...){tick} を使わず、{tick}[0-9]{tick} と通常の括弧を使います。
日時を囲む括弧の前に別のキャプチャ括弧を置くと、別の値が日時扱いになる点に注意してください。

JSON設定ファイルを使う場合の例：""")
code('''{
  "events": {
    "message_time_regex": "\\"eventTime\\"[[:space:]]*:[[:space:]]*\\"([^\\"]+)\\"",
    "message_timezone": "Asia/Tokyo"
  }
}''', "json")
paragraph("**7. 実行例と期待する結果**")
code('''./cwlog -g /aws/your/log-group \\
  --start '2026-10-26 10:00:00' \\
  --end '2026-10-26 11:00:00' \\
  --timezone Asia/Tokyo \\
  --engine filter \\
  --limit 1000 \\
  --excel ./output/message-time-check.xlsx''')
paragraph(f"""ロググループ名を実際の名前へ置き換え、出力名は既存ファイルと重複しないものを指定します。
本文の日時が日本時間の場合の期待値は次のとおりです。

| 本文日時 | イベント時刻 | 期待結果 |
|---|---|---|
| 10:30:00 | 12:00:00（期間外） | 出力対象 |
| 09:59:59.999 | 10:30:00（期間内） | 除外 |
| 10:00:00.000 | 前日 | 出力対象 |
| 11:00:00.000 | 翌日 | 出力対象 |
| 11:00:00.001 | 10:30:00 | 除外 |
| 日時なし | 10:30:00 | 除外して警告件数に加算 |
| 2026-02-30などの不正日付 | 10:30:00 | 除外して警告件数に加算 |

{tick}--end '... 11:00:00'{tick} は11:00:00.000までで、11:00:00.001は含みません。
上限を超える場合は本文で絞り込んだ結果から、イベント時刻の新しい側のN件が出力されます。
Excelのメッセージ列で判定結果を確認してください。「日時」列はイベント時刻なので範囲外のことがあります。
該当0件の場合は既存動作どおり警告して終了し、新しいExcelは作りません。
確認時は新しい出力名を使い、既存のExcelを今回の結果と取り違えないようにします。

**8. 閉域網での検証**

まず構文を確認します。AWSへの接続は不要です。""")
code("bash -n cwlog\nbash -n lib/config.sh\nbash -n lib/logs.sh\n# この設定ファイルを利用している場合\nbash -n cwlog.conf")
paragraph("何も表示されず終了コード0なら構文確認は成功です。付属テストを配置できる場合は次を実行します。")
code("bash tests/message_time_test.sh")
paragraph(f"""テストはAWS応答を差し替えており、AWS接続・認証情報は不要です。
既存の動作要件のBash、GNU date、gawk、jq、coreutils、zipまたはbsdtar、tzdataを使います。
本文とイベント時刻のずれ、両端の境界、小数秒、日時なし、不正日付、独自抽出条件、
タイムゾーン、後からの件数制限、並び順、ストリーム、通常の取得経路、設定読み込み、
エラー伝播、実際のExcelアーカイブ生成を確認します。
全15項目が通れば {tick}All 15 tests passed. No AWS connection was made.{tick} と表示します。
その後、実環境の既知のログで「本文は期間内、イベント時刻は期間外」の行が含まれることを確認してください。

**9. 今回実施した検証・未実施事項**

- Windows版ShellCheck 0.11.0による {tick}shellcheck --external-sources cwlog{tick} の修正前後の診断は同一です。
  新しい診断はありません。既存のARG_name_filter_set未使用警告（SC2034）は残っています。
- {tick}shellcheck --external-sources --severity=error cwlog lib/logs.sh tests/message_time_test.sh{tick} はエラーなしです。
- config.sh単体の解析では、既存の動的配列代入にSC1087が出ます（修正前169行／修正後172行）。
  今回の変更箇所ではありません。
- {tick}git diff --check{tick} とUTF-8・BOM・LF改行を確認しました。
- 本手順の変更前→変更後を適用すると、修正済み3ファイルをバイト単位で再現できることを確認しました。
- **Bash実行テストは未実行です。** 作業環境のGit Bashは
  {tick}couldn't create signal pipe, Win32 error 5{tick}、WSLは {tick}E_ACCESSDENIED{tick} で起動できませんでした。
  上記15項目のテストが成功することは、こちらでは実行確認していません。
- AWS実環境での取得、実データの処理時間の計測、Microsoft Excelアプリの表示確認も未実施です。
  閉域網のRHELで構文確認、付属テスト、既知ログによる確認を行ってから運用へ反映してください。

**10. ファイル・パッチを持ち込める場合**

上記コミットと同じ版で現場独自の変更がない場合は、修正済み本体3ファイルを置き換える方法もあります。
本体3ファイルだけの差分 {tick}message-time-fix.patch{tick} もリポジトリの1階層上に用意しています。
パッチを1階層上に配置し、プロジェクトのルートで実行します。""")
code("git apply --check ../message-time-fix.patch\ngit apply ../message-time-fix.patch\ngit diff --check")
paragraph("""最初の確認が失敗した場合は適用せず、対象版・現場変更・改行を確認してください。
このパッチには設定の例・手順書・テストを含みません。
手作業とパッチの両方で同じ修正を重複適用しないでください。

説明コメントまで同一で、UTF-8/BOMなし/LFの場合のSHA-256：

| ファイル | SHA-256 |
|---|---|""")
for f in files:
    digest = hashlib.sha256((repo / f).read_bytes()).hexdigest()
    out.append(f"| {tick}{f}{tick} | {tick}{digest}{tick} |\n")
out.append("\n")
paragraph("""現場独自の変更や改行差がある場合は一致しません。ハッシュを一致させるために必要な現場変更を消さないでください。

**11. 元へ戻す場合**

手順4で表示されたバックアップ先から3ファイルを戻します。
下のbackup_dirには実際のディレクトリ名を指定します。""")
code('''backup_dir='./cwlog-before-message-time.実際の値'
cp -p -- "$backup_dir/cwlog" cwlog
cp -p -- "$backup_dir/lib/config.sh" lib/config.sh
cp -p -- "$backup_dir/lib/logs.sh" lib/logs.sh
# cwlog.confもバックアップし、その後変更した場合だけ実行
# cp -p -- "$backup_dir/cwlog.conf" cwlog.conf
bash -n cwlog
bash -n lib/config.sh
bash -n lib/logs.sh''')
manual = "".join(out)
(repo / "MANUAL_FIX.md").write_bytes(manual.encode("utf-8"))
patch = subprocess.check_output(["git", "diff", "--binary", "--", *files], cwd=repo)
(workspace / "message-time-fix.patch").write_bytes(patch)
print("PASS: all manual replacements reproduce the fixed files exactly.")
print(f"MANUAL_FIX.md: {len(manual.splitlines())} lines; patch: {len(patch)} bytes")
for i, (file, old, new, _, a, b) in enumerate(edits, 1):
    print(f"5-{i}: {file}: {a}-{a + old.count(chr(10)) - 1} -> {b}-{b + new.count(chr(10)) - 1}")
