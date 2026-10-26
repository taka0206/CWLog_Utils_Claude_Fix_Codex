# CWLog Utils

指定した AWS アカウント環境の **CloudWatch Logs ロググループをフィルタして一覧表示**し、
選択したロググループのログを **ログストリームを介さず直接表示**する CLI ツールです。
既定では **最新のログストリームのみ**を **時系列の昇順（古い順）** で表示し、
オプションで並び順の切替や全ログストリームの横断取得もできます。
テキスト / Excel への出力と、エラー・警告・通常行のカラーリングに対応しています。

**RHEL 9.8 上の bash + AWS CLI + 標準コマンド**だけで動作します（Python 不要）。

---

## 主な機能

| 機能 | 内容 |
|---|---|
| ロググループのフィルタ一覧 | 名前の部分一致 / 正規表現で絞り込み、番号付きで一覧表示 |
| 対話選択 | 一覧から番号で選択。一覧上でさらに絞り込み・ページ送りが可能 |
| ログの直接表示 | `FilterLogEvents` で取得し、ログストリームを選ぶ操作なしで表示 |
| 最新ログストリームの自動特定 | 既定で **最新のログストリーム 1 本だけ**を対象にする（`--all-streams` で全ストリーム横断） |
| 時系列の並び順切替 | `--asc`（既定・古い順）/ `--desc`（新しい順） |
| カラーリング | エラー行=赤 / 警告行=黄 / 通常行=既定色。判定パターンは設定で変更可能 |
| テキスト出力 | メタ情報付きのテキストファイル（ANSI カラー埋め込みも可） |
| Excel 出力 | サマリシート＋ログシート。レベル別に行を塗り分け、オートフィルタ・ウィンドウ枠固定付き |
| 事前認証チェック | 起動時に STS で認証状態を確認。未認証なら `aws login --remote` を案内して終了 |
| スイッチバック | CloudWatch Logs の操作権限が無い場合、**警告して終了**するか、**専用シェルを `source` して自動スイッチバック**するかをオプションで切替 |

---

## 動作要件

| コマンド | 用途 | RHEL 9.8 での入手方法 |
|---|---|---|
| `bash` 4.2 以降 | 本体 | 標準 (RHEL 9 は 5.1) |
| `aws` (AWS CLI v2 推奨、v1 も可) | AWS API 呼び出し | [AWS 公式インストーラ](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| `jq` | JSON レスポンスの解析 | `dnf install -y jq` |
| `gawk` (GNU awk) | 整形・レベル判定・出力生成 | 標準 (`dnf install -y gawk`) |
| `coreutils` (`date` `sort` `mktemp` など) | 日時計算・整列 | 標準 |
| `zip`（Excel 出力時のみ） | `.xlsx` の作成 | `dnf install -y zip`（`bsdtar` でも可） |
| `tzdata` | タイムゾーン表示 | 標準 |

```bash
sudo dnf install -y jq gawk zip
```

## セットアップ

```bash
git clone <このリポジトリ> && cd CWLog_Utils_Claude
chmod +x cwlog cwlog.sh

# 設定ファイルを使う場合
cp cwlog.sample.conf cwlog.conf

# 任意: PATH の通った場所へリンク
ln -s "$PWD/cwlog" ~/bin/cwlog
```

---

## 使い方

### 起動方法

```bash
# 直接実行
./cwlog [オプション]

# シェルラッパー経由（推奨: スイッチバックが現在のシェルに残る）
source ./cwlog.sh [オプション]
```

### 基本的な流れ

```bash
# 1. ロググループ名で絞り込み → 一覧から番号で選択
#    → 直近24時間・最新ログストリームのログを昇順表示
./cwlog --profile prod --filter /aws/lambda/

# 2. ロググループを直接指定して、直近6時間分をテキストと Excel に出力
./cwlog -g /aws/lambda/order-api --hours 6 --text --excel

# 3. 一覧だけ見る
./cwlog --filter api --list-only

# 4. エラー・警告だけを抽出して Excel 化
./cwlog -g /aws/ecs/batch --level warn+ --excel ./report/errors.xlsx

# 5. 新しい順に、ロググループ内の全ログストリームを横断して表示
./cwlog -g /aws/lambda/order-api --desc --all-streams
```

`--filter` を省略して対話実行すると、起動時にフィルタ文字列を尋ねます。

### 一覧画面の操作

```
    No  ロググループ名                サイズ      保持
  -----------------------------------------------------
     1  /aws/lambda/order-api          1.0MB      30日
     2  /aws/lambda/payment-api       50.0MB    無期限

番号を入力して選択 [ /文字列=絞込, n=次, p=前, r=絞込解除, q=中止 ] >
```

| 入力 | 動作 |
|---|---|
| `3` | 3 番のロググループを選択 |
| `/payment` | 一覧をさらに絞り込む（正規表現も可） |
| `n` / `p` | 次ページ / 前ページ |
| `r` | 絞り込みを解除 |
| `q` | 中止 |

---

## 認証チェック

起動時に `aws sts get-caller-identity` を呼び、事前認証が済んでいるかを確認します。
未認証・トークン失効の場合は次のように警告して **終了コード 2** で終了します。

```
========================================================================
  [認証エラー] AWS への事前認証が完了していません。
========================================================================

  先に下記のコマンドを実行して認証を行ってから、再度実行してください。

      aws login --remote

  詳細: Unable to locate credentials
```

案内するコマンドは `--login-command` / 設定ファイルの `auth_login_command` /
環境変数 `CWLOG_LOGIN_COMMAND` で変更できます。

---

## スイッチバック

CodeCommit 用ロールなど、CloudWatch Logs を操作できない権限のまま実行された場合の挙動を
`--switchback-mode` で切り替えます。判定は `logs:DescribeLogGroups` の実行可否で行います。

| モード | 動作 |
|---|---|
| `warn`（既定） | 警告メッセージを表示して **終了コード 3** で終了 |
| `auto` | 別チーム提供のスイッチバック用シェルを `source` して自動的に権限を切り替え、処理を継続 |
| `off` | 権限チェックを行わない |

### warn モード

```
========================================================================
  [権限エラー] 現在の権限では AWS (CloudWatch Logs) を操作できません。
========================================================================

  現在の ID : arn:aws:sts::123456789012:assumed-role/CodeCommitOnlyRole/me
  アカウント: 123456789012
  ※ CodeCommit 用ロールのままである可能性があります。

  スイッチバックしてから再実行してください。

      source /opt/team/aws/switch_role.sh

  自動でスイッチバックする場合は --switchback-mode auto を指定してください。
```

### auto モード

```bash
./cwlog -g /aws/lambda/order-api \
    --switchback-mode auto \
    --switchback-script /opt/team/aws/switch_role.sh \
    --switchback-arg prod
```

```
[スイッチバック] /opt/team/aws/switch_role.sh を source して権限を切り替えます...
  | switching role to AppAdminRole...
[スイッチバック] 完了しました (取り込み: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
[スイッチバック] 権限を確認しました: arn:aws:sts::123456789012:assumed-role/AppAdminRole/me
```

権限の有無に関わらず起動時に必ずスイッチバックしたい場合は `--switchback-now` を使います。

### シェルの配置場所の指定

スイッチバック用シェルのパスは、以下のいずれでも指定できます（下ほど優先）。

1. 設定ファイルの `switchback_script`
2. 環境変数 `CWLOG_SWITCHBACK_SCRIPT`
3. コマンドライン `--switchback-script <PATH>`

シェルへ渡す引数は `--switchback-arg`（複数指定可）または `switchback_args` で指定します。

### スイッチバックの仕組みと `cwlog.sh`

本ツールはシェルスクリプトなので、スイッチバック用シェルを **自プロセスで直接 `source`**
します。ツール実行中の権限は確実に切り替わりますが、`./cwlog` を直接実行した場合は
**終了後のシェルには残りません**。

終了後も切り替わった権限を残したい場合は、`cwlog.sh` を `source` で起動してください。
この場合、ラッパーが *呼び出し元のシェル自身* で専用シェルを `source` します。

```bash
source ./cwlog.sh -g /aws/lambda/order-api \
    --switchback-mode auto --switchback-script /opt/team/aws/switch_role.sh
# → 実行後もスイッチバック後の権限が現在のシェルに残る
```

> **`--switchback-isolated`**
> スイッチバック用シェルが `exit` や `set -e` を行う作りだと、直接 `source` した
> 本ツールごと終了してしまう可能性があります。その場合は `--switchback-isolated`
> （設定では `switchback_isolated=1`）を指定してください。別プロセスのシェルで
> `source` を実行し、結果の `AWS_*` 環境変数だけを取り込む方式に切り替わります。
> `source` を実行するシェルは `--switchback-shell` で変更できます（既定 `bash`）。

---

## カラーリング

各行を正規表現で判定し、レベルごとに色を付けます。

| レベル | 画面 | Excel | 既定の判定パターン（抜粋） |
|---|---|---|---|
| ERROR | 明るい赤 | 赤系の塗りつぶし | `ERROR` `FATAL` `CRITICAL` `Exception` `Traceback` `Caused by:` `AccessDenied` `エラー` `失敗しました` `異常終了` `致命的` |
| WARN | 明るい黄 | 黄系の塗りつぶし | `WARN` `WARNING` `CAUTION` `DEPRECATED` `retry` `throttl*` `警告` `注意` `リトライ` |
| INFO | 既定色 | 白 | 上記以外 |

`errors=0` や `"warnings": []` のような表現を誤検知しないよう、除外パターンも用意しています。
判定パターンは設定ファイルの `colors_error_patterns` / `colors_warn_patterns` /
`colors_exclude_patterns` で自由に変更できます（すべて大文字小文字を区別しません）。

正規表現は **gawk の拡張 ERE** です。Perl 互換の `\b`（単語境界）は使えないため
**`\y`** を、`\w` の代わりに `[[:alnum:]_]` を使用してください。

複数行メッセージ（スタックトレースなど）は、含まれる行のうち **最も重いレベル** が採用されます。

カラー表示は `--no-color` で無効化、`--color` で強制有効化できます。
`NO_COLOR` 環境変数、パイプ／リダイレクト時の自動無効化にも対応しています
（`CWLOG_FORCE_COLOR` を設定すると常に有効）。

---

## 出力

`--text` / `--excel` はパスを省略すると `export_dir`（既定 `./output`）に自動命名で出力します。

```bash
./cwlog -g /aws/lambda/order-api --text --excel                 # 自動命名
./cwlog -g /aws/lambda/order-api --text ./log.txt --excel ./log.xlsx
./cwlog -g /aws/lambda/order-api --excel --out-dir ./reports
```

**テキスト出力**: 先頭にアカウント・期間・件数などのメタ情報、以降は
`[日時] [レベル] [ログストリーム] メッセージ` 形式。
`--text-ansi` を付けると ANSI カラーを埋め込みます（`less -R` で色付き表示）。

**Excel 出力**: 2 シート構成。OpenXML を直接生成するため外部ライブラリは不要です
（`zip` または `bsdtar` コマンドのみ使用）。

- `サマリ` — アカウント、ロググループ、ログストリーム、期間、並び順、エンジン、レベル別件数
- `ログ` — `No / 日時 / レベル / ログストリーム / メッセージ`。レベル別に行を塗り分け、
  1 行目固定・オートフィルタ・メッセージ列は折り返し表示

---

## 取得エンジン

| エンジン | 説明 |
|---|---|
| `filter`（既定） | `FilterLogEvents` を使用。期間を**新しい側から後方へチャンク分割**して呼び出し、必要件数が集まった時点で打ち切るため、全期間をスキャンせずに降順取得できます |
| `insights` | CloudWatch Logs Insights の `sort @timestamp desc` を使用。サーバ側でソートされます（`logs:StartQuery` / `logs:GetQueryResults` 権限とクエリ課金が必要） |

```bash
./cwlog -g /aws/lambda/order-api --engine insights -n 500
```

---

## 並び順と対象ログストリーム

### 時系列の並び順

| オプション | 表示順 |
|---|---|
| `--asc` / `--order asc` | **昇順（古い順）— 既定**。ログファイルを `tail` で追うのと同じ並び |
| `--desc` / `--order desc` | 降順（新しい順）。最新のエラーをすぐ確認したいとき |

取得そのものは常に**新しい側から** `--limit` 件ぶん集め、最後に指定の並び順へ整列します。
そのため `--asc` でも「直近 N 件を古い順に並べたもの」が表示されます
（期間の先頭から N 件ではありません）。期間の先頭側を見たい場合は
`--start` / `--end` で範囲そのものを狭めてください。

### 対象ログストリーム

| オプション | 対象 |
|---|---|
| `--latest-stream` | **最新のログストリーム 1 本のみ — 既定**（`--start` / `--end` 指定時は全ストリームを横断。後述） |
| `--all-streams`（別名 `--no-latest-stream`） | ロググループ内の全ログストリームを横断 |

`--latest-stream` では `DescribeLogStreams` を `LastEventTime` の降順で走査し、
**指定期間とイベント期間が重なる最初の 1 本**を採用します。走査する本数は
`events_stream_scan_limit`（既定 50）で調整できます。
採用したストリーム名は画面のヘッダとテキスト / Excel のメタ情報に記録されます。

```
対象ロググループ: /aws/lambda/order-api
対象ストリーム  : 2026/09/08/[$LATEST]abcdef0123456789
  期間: 2026-09-07 13:00:00 〜 2026-09-08 13:00:00  /  上限 1000 件  /  エンジン filter  /  並び 昇順(古い順)
```

次の場合は警告を出したうえで、**自動的に全ログストリーム対象へフォールバック**して続行します。

- 指定期間にイベントを持つログストリームが 1 本も見つからなかった
  （`lastEventTimestamp` は結果整合性で更新され、数分〜1 時間程度遅れることがあります。
  ごく短い期間を指定すると特定できない場合があります）
- `logs:DescribeLogStreams` の権限が無い
  （この絞り込みは付加的な機能のため、権限が無くても従来どおり動作します）

Lambda のように実行のたびに新しいログストリームが作られる環境では、
`--latest-stream`（既定）が「直近 1 実行分のログ」に相当します。
複数の実行やコンテナをまたいで追いたい場合は `--all-streams` を指定してください。

#### `--start` / `--end` で期間を指定した場合

`--start` または `--end` で期間を明示した場合は、その期間がログストリームの
切り替わりをまたぐことがあるため、`--all-streams` を付けなくても
**全ログストリームを横断して取得**します（`--hours` のみの指定では従来どおり最新 1 本）。

```bash
# 10/15 0 時〜10/17 0 時のログを、ストリームの切り替わりをまたいで取得
./cwlog -g /aws/lambda/order-api --start '2026-10-15 00:00' --end '2026-10-17 00:00'
```

```
対象ストリーム  : 全ログストリーム (期間指定のためストリームを横断)
```

期間を指定しつつ最新の 1 本だけに絞りたい場合は、コマンドラインで
`--latest-stream` を明示してください（設定ファイルの `events_latest_stream=1` だけでは絞りません）。

---

## 主なオプション

```
AWS 接続
  --profile, -P     使用する AWS プロファイル（アカウント環境）
  --region, -r      対象リージョン（既定 ap-northeast-1）
  --config, -c      設定ファイル（.conf / .json）のパス

認証 / スイッチバック
  --login-command       未認証時に案内するログインコマンド
  --skip-auth-check     事前認証チェックをスキップ
  --switchback-mode     off | warn | auto
  --switchback-script   スイッチバック用シェルのパス
  --switchback-arg      シェルへ渡す引数（複数指定可）
  --switchback-isolated 別プロセスで source し AWS_* 環境変数だけを取り込む
  --switchback-shell    isolated 実行時に source を行うシェル（既定 bash）
  --switchback-now      権限の有無に関わらず起動時にスイッチバック

ロググループ選択
  --filter, -f      ロググループ名の絞り込み文字列
  --regex           --filter を正規表現として扱う
  --group, -g       ロググループ名を直接指定（一覧選択をスキップ）
  --list-only, -l   一覧のみ表示して終了
  --max-groups      一覧の最大件数（既定 500）

ログ取得
  --hours, -H       直近何時間分か（既定 24）
  --start, -s       開始日時（'2026-09-01 10:00:00' / ISO8601 / '-3h' など）
  --end, -e         終了日時（既定 現在）
  --limit, -n       取得件数の上限（既定 1000）
  --pattern, -p     メッセージのフィルタパターン（CloudWatch フィルタ構文）
  --engine          filter | insights
  --order           asc | desc（既定 asc）
  --asc / --desc    時系列の昇順 / 降順（--order の短縮形）
  --latest-stream   最新のログストリームのみを対象にする（既定）
                    ※ --start / --end 指定時は全ストリームを横断（明示時のみ 1 本に絞る）
  --all-streams     全ログストリームを横断して取得する
  --timezone, -z    表示タイムゾーン（既定 Asia/Tokyo）
  --level           all | error | warn | warn+

表示 / 出力
  --no-color / --color   カラー表示の無効化 / 強制
  --quiet, -q            ログ本文を画面に表示しない
  --text, -t [PATH]      テキスト出力
  --excel, -x [PATH]     Excel 出力
  --out-dir, -o          出力先ディレクトリ（既定 ./output）
  --text-ansi            テキスト出力にも ANSI カラーを埋め込む
  --yes, -y              対話プロンプトを省略
```

長いオプションは `--limit=100` の形式でも指定できます。

---

## 設定ファイル

`cwlog.conf`（または `.cwlog.conf` / `cwlog.json` / `.cwlog.json`）を以下の順で探索します。

1. `--config` で明示指定したパス
2. カレントディレクトリ
3. スクリプト配置ディレクトリ
4. `~/.config/cwlog/`
5. `~/`

優先順位は **デフォルト < 設定ファイル < 環境変数 < コマンドライン引数** です。
設定項目の詳細は [`cwlog.sample.conf`](cwlog.sample.conf) を参照してください。

`.conf` は **bash として `source`** されます。`aws_region="us-east-1"` のように
`セクション名_キー名` の変数へ代入してください（配列も指定可）。
JSON 形式（`{"aws": {"region": "us-east-1"}}`）も利用できます（`jq` が必要）。

### 環境変数

| 環境変数 | 対応する設定 |
|---|---|
| `CWLOG_PROFILE` / `AWS_PROFILE` | `aws_profile` |
| `CWLOG_REGION` / `AWS_REGION` | `aws_region` |
| `CWLOG_LOGIN_COMMAND` | `auth_login_command` |
| `CWLOG_SWITCHBACK_MODE` | `switchback_mode` |
| `CWLOG_SWITCHBACK_SCRIPT` | `switchback_script` |
| `CWLOG_SWITCHBACK_SHELL` | `switchback_shell` |
| `CWLOG_OUTPUT_DIR` | `export_dir` |
| `CWLOG_TIMEZONE` | `events_timezone` |
| `CWLOG_FORCE_COLOR` / `NO_COLOR` | カラー表示の強制 / 無効化 |

---

## 必要な IAM 権限

- `sts:GetCallerIdentity`（認証チェック）
- `logs:DescribeLogGroups`（一覧・権限チェック）
- `logs:DescribeLogStreams`（`--latest-stream`。既定で有効。無い場合は警告のうえ全ストリーム対象で続行）
- `logs:FilterLogEvents`（`filter` エンジン）
- `logs:StartQuery`, `logs:GetQueryResults`, `logs:StopQuery`（`insights` エンジンのみ）

---

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 正常終了 |
| 1 | 一般エラー（対象なし、AWS API エラーなど） |
| 2 | 未認証（`aws login --remote` が必要） |
| 3 | 権限不足（スイッチバックが必要） |
| 130 | ユーザーによる中止 |

---

## ファイル構成

```
CWLog_Utils_Claude/
├── cwlog                 本体（bash）
├── cwlog.sh              シェルラッパー（source 起動でスイッチバックを維持）
├── cwlog.sample.conf     設定サンプル
└── lib/
    ├── config.sh         設定の読み込みとマージ
    ├── colors.sh         ANSI カラー出力
    ├── auth.sh           認証チェック・権限チェック・スイッチバック
    ├── logs.sh           CloudWatch Logs アクセス（一覧・最新ストリーム特定・イベント取得）
    ├── exporter.sh       テキスト / Excel(OpenXML) 出力
    ├── classify.awk      共通関数（レベル判定・時刻整形・表示幅・XML エスケープ）
    ├── annotate.awk      レベル付与と --level 絞り込み
    ├── render.awk        画面表示
    ├── groups.awk        ロググループ一覧表示
    ├── text.awk          テキスト出力
    ├── xlsx.awk          Excel ログシート生成
    └── xlsx_summary.awk  Excel サマリシート生成
```

内部では、ログイベントを `発生時刻(epoch ミリ秒) \t ログストリーム \t メッセージ` の
TSV（改行・タブは `jq` の `@tsv` でエスケープ）として受け渡し、`sort` で `--order` の
指定どおりに整列してから gawk で整形しています。

---

## Python 版からの変更点

以前の Python 実装（`boto3` / `openpyxl` / `PyYAML`）を bash へ全面的に置き換えました。
機能・画面表示・終了コードは踏襲していますが、次の点が変わっています。

| 項目 | Python 版 | シェル版 |
|---|---|---|
| 実行 | `python cwlog.py` | `./cwlog` |
| AWS アクセス | boto3 | AWS CLI + jq |
| Excel 出力 | openpyxl | OpenXML を直接生成（`zip` コマンド） |
| 設定ファイル | YAML / JSON | **`.conf`（bash 形式）/ JSON**（YAML は非対応） |
| 設定キー | `aws.region` | `aws_region`（`セクション_キー`） |
| 正規表現 | Python 正規表現（`\b` `\w` `(?:)`） | gawk 拡張 ERE（`\y` `[[:alnum:]_]` `()`） |
| スイッチバック | 常にサブシェルで `source` して環境変数を回収 | 既定は自プロセスで直接 `source`（`--switchback-isolated` で従来方式） |
| 一覧の桁揃え | 文字数基準（日本語見出しがずれる） | 表示幅基準（全角を 2 桁として整列） |

`--switchback-shell` は `--switchback-isolated` 指定時のみ意味を持ちます。
`CWLOG_PYTHON` 環境変数は廃止しました。
