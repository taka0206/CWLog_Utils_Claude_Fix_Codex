#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# logs.sh - CloudWatch Logs へのアクセス層
#
# ロググループ一覧の取得と、ログストリームを介さずに直接ログイベントを
# 取得する処理を提供する。
#
# 取得エンジン:
#   filter   : FilterLogEvents API をロググループ単位で呼び出す。
#              新しい時間帯から後方へチャンク走査することで、
#              全件スキャンせずに新しい側から取得する。
#   insights : CloudWatch Logs Insights (sort @timestamp desc) を利用し、
#              サーバ側で降順ソートさせる。
#
# いずれのエンジンも「新しい側から上限件数ぶん」を集め、最後に --order
# (asc / desc) の指定に従って並べ替える。最新ログストリームのみを対象と
# する場合は、DescribeLogStreams で 1 本に絞ってから取得する。
#
# 中間データは TSV (タブ区切り) で受け渡す。
#   ロググループ: 名前 \t 保存バイト数 \t 保持日数
#   ログイベント: 発生時刻(epoch ミリ秒) \t ログストリーム \t メッセージ
# メッセージ中の改行・タブは jq の @tsv により \n \t へエスケープされる。
# ---------------------------------------------------------------------------

# FilterLogEvents の 1 ページあたり最大件数
CW_MAX_FILTER_PAGE=10000

# ---------------------------------------------------------------------------
# ロググループ一覧
#   cw_list_log_groups <絞込文字列> <正規表現?0/1> <最大件数> <出力ファイル>
# ---------------------------------------------------------------------------
cw_list_log_groups() {
    local name_filter=$1 use_regex=$2 max_items=$3 outfile=$4
    local raw="$CW_TMPDIR/groups.json"
    local rc=0

    cw_aws_run "$raw" logs describe-log-groups || rc=$?
    if ((rc != 0)); then
        if cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
            cw_say_err "[エラー] ロググループの一覧取得を拒否されました: $(cw_aws_err_summary)"
            return 3
        fi
        cw_say_err "[AWS エラー] $(cw_aws_err_summary)"
        return 1
    fi

    # 正規表現の妥当性を先に確認する
    #   ※ 正規表現は -v ではなく環境変数で渡す (-v はエスケープが解釈されるため)
    if [[ -n $name_filter ]] && cw_is_true "$use_regex"; then
        if ! CW_NAME_FILTER="$name_filter" awk \
                'BEGIN { if ("" ~ ENVIRON["CW_NAME_FILTER"]) exit 0; exit 0 }' \
                2>"$CW_TMPDIR/re.err"; then
            cw_say_err "[エラー] ロググループ名の正規表現が不正です: $name_filter"
            cw_say_err "  $(head -2 "$CW_TMPDIR/re.err" | tr '\n' ' ')"
            return 1
        fi
    fi

    jq -r '.logGroups[]? | [.logGroupName, (.storedBytes // -1 | tostring), (.retentionInDays // 0 | tostring)] | @tsv' \
        "$raw" \
        | CW_NAME_FILTER="$name_filter" awk -F'\t' -v OFS='\t' \
              -v useRe="$use_regex" -v maxItems="$max_items" '
            BEGIN {
                IGNORECASE = 1
                n = 0
                filter = ENVIRON["CW_NAME_FILTER"]
                lower = tolower(filter)
                useRegex = (useRe == "1" || useRe == "true" || useRe == "yes" || useRe == "on")
            }
            {
                if (filter != "") {
                    if (useRegex) {
                        if ($1 !~ filter) next
                    } else {
                        if (index(tolower($1), lower) == 0) next
                    }
                }
                print
                if (++n >= maxItems + 0) exit
            }
        ' > "$outfile"
    return 0
}

# ---------------------------------------------------------------------------
# 最新のログストリームを 1 本だけ特定する
#   cw_resolve_latest_stream <ロググループ> <開始ms> <終了ms>
#
# DescribeLogStreams を LastEventTime の降順で走査し、指定期間とイベント
# 期間が重なる最初のログストリーム名を標準出力へ返す。
# 該当が無ければ空文字を返す (呼び出し側で全ストリーム対象へ戻す)。
#
# 戻り値 3 は logs:DescribeLogStreams の権限不足を表す。この絞り込みは
# 付加的な機能であるため、呼び出し側は全ストリーム対象へ戻して継続する。
#
# ※ ストリーム名以外の出力は必ず標準エラーへ出す (標準出力は戻り値)。
# ※ lastEventTimestamp は結果整合性で更新される (数分〜1 時間程度遅れる
#    ことがある) ため、ごく短い期間を指定した場合は取りこぼしうる。
# ---------------------------------------------------------------------------
cw_resolve_latest_stream() {
    local group=$1 start_ms=$2 end_ms=$3
    local out="$CW_TMPDIR/streams.json"
    local scan=${CFG_events_stream_scan_limit:-50}
    ((scan < 1)) && scan=1

    local -a args=(
        logs describe-log-streams
        --log-group-name "$group"
        --order-by LastEventTime
        --descending
        --max-items "$scan"
    )

    local rc=0
    cw_aws_run "$out" "${args[@]}" || rc=$?
    if ((rc != 0)); then
        if cw_aws_err_matches 'ResourceNotFoundException'; then
            cw_say_err "[エラー] ロググループが存在しません: $group"
            return 4
        fi
        if cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
            cw_say_warn "[警告] ログストリームの一覧取得を拒否されました (logs:DescribeLogStreams)" >&2
            cw_say_warn "       $(cw_aws_err_summary)" >&2
            return 3
        fi
        cw_say_err "[AWS エラー] $(cw_aws_err_summary)"
        return 1
    fi

    # イベントを持ち、かつ指定期間と重なる最初のストリームを採用する
    jq -r --argjson s "$start_ms" --argjson e "$end_ms" '
        [ .logStreams[]?
          | select((.lastEventTimestamp // 0) > 0)
          | select((.lastEventTimestamp // 0) >= $s)
          | select((.firstEventTimestamp // .lastEventTimestamp) <= $e)
        ]
        | (first // {})
        | .logStreamName // ""
    ' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# ログイベント取得
#   cw_fetch_events <ロググループ> <開始ms> <終了ms> <上限> <パターン>
#                   <エンジン> <並び順> <ログストリーム> <出力ファイル>
#
# <ログストリーム> が空文字のときはロググループ全体を横断して取得する。
# ---------------------------------------------------------------------------
cw_fetch_events() {
    local group=$1 start_ms=$2 end_ms=$3 limit=$4 pattern=$5
    local engine=$6 order=$7 stream=$8 outfile=$9
    local raw="$CW_TMPDIR/events_raw.tsv"
    : > "$raw"
    local rc=0

    if [[ $engine == insights ]]; then
        cw_fetch_via_insights "$group" "$start_ms" "$end_ms" "$limit" "$pattern" \
            "$stream" "$raw" || rc=$?
    else
        cw_fetch_via_filter "$group" "$start_ms" "$end_ms" "$limit" "$pattern" \
            "$stream" "$raw" || rc=$?
    fi
    ((rc != 0)) && return $rc

    # (時刻, ログストリーム) で整列して上限件数まで切り出す
    if [[ $order == asc ]]; then
        LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$raw" | head -n "$limit" > "$outfile"
    else
        LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r "$raw" | head -n "$limit" > "$outfile"
    fi
    return 0
}

# --- filter エンジン --------------------------------------------------------
# FilterLogEvents を新しい時間帯から後方へチャンク走査する。
# FilterLogEvents は昇順にしか返らないため、期間を分割して
# 「新しいチャンクから順に」取得することで、全件スキャンせずに
# 降順の結果を組み立てる。
cw_fetch_via_filter() {
    local group=$1 start_ms=$2 end_ms=$3 limit=$4 pattern=$5 stream=$6 raw=$7
    local chunk_max=${CFG_events_chunk_max_seconds:-21600}
    local max_chunks=${CFG_events_max_chunks:-240}

    local total_sec=$(( (end_ms - start_ms) / 1000 ))
    ((total_sec < 1)) && total_sec=1
    ((chunk_max < 60)) && chunk_max=60

    local chunk_sec=$((total_sec / 8))
    ((chunk_sec < 60)) && chunk_sec=60
    ((chunk_sec > chunk_max)) && chunk_sec=$chunk_max

    # FilterLogEvents の startTime / endTime はどちらも境界を含むため、
    # 次のチャンクの終端を「前チャンクの始端 - 1ms」にして重複を防ぐ
    local cursor_end=$end_ms
    local chunks=0 collected=0 before after cursor_start rc=0

    while ((cursor_end >= start_ms && collected < limit && chunks < max_chunks)); do
        chunks=$((chunks + 1))
        cursor_start=$((cursor_end - chunk_sec * 1000))
        ((cursor_start < start_ms)) && cursor_start=$start_ms

        cw_progress "取得中: $(cw_fmt_short "$cursor_start") 〜 $(cw_fmt_short "$cursor_end") (取得済 ${collected} 件)"

        before=$collected
        rc=0
        cw_filter_range "$group" "$cursor_start" "$cursor_end" "$pattern" \
            $((limit - collected)) "$stream" "$raw" || rc=$?
        ((rc != 0)) && return $rc

        after=$(wc -l < "$raw")
        collected=$((after))
        cursor_end=$((cursor_start - 1))

        # 件数が少ないチャンクが続く場合は幅を広げて走査を早める
        if ((collected == before)); then
            chunk_sec=$((chunk_sec * 2))
            ((chunk_sec > chunk_max)) && chunk_sec=$chunk_max
        fi
    done
    return 0
}

# 指定した時間範囲を 1 回分取得して raw へ追記する
cw_filter_range() {
    local group=$1 start_ms=$2 end_ms=$3 pattern=$4 remaining=$5 stream=$6 raw=$7
    local out="$CW_TMPDIR/filter.json"
    local page_size=$remaining
    ((page_size > CW_MAX_FILTER_PAGE)) && page_size=$CW_MAX_FILTER_PAGE
    ((page_size < 1)) && page_size=1

    local -a args=(
        logs filter-log-events
        --log-group-name "$group"
        --start-time "$start_ms"
        --end-time "$end_ms"
        --max-items "$remaining"
        --page-size "$page_size"
    )
    [[ -n $pattern ]] && args+=(--filter-pattern "$pattern")
    [[ -n $stream  ]] && args+=(--log-stream-names "$stream")

    local attempt rc
    for attempt in 1 2 3 4 5; do
        rc=0
        cw_aws_run "$out" "${args[@]}" || rc=$?
        if ((rc == 0)); then
            jq -r '.events[]? | [(.timestamp // 0 | tostring), (.logStreamName // ""), ((.message // "") | sub("\n+$"; ""))] | @tsv' \
                "$out" >> "$raw"
            return 0
        fi
        if cw_aws_err_matches 'ResourceNotFoundException'; then
            cw_say_err "[エラー] ロググループが存在しません: $group"
            return 4
        fi
        if cw_aws_err_matches 'ThrottlingException|Rate exceeded|TooManyRequests'; then
            sleep 1
            continue
        fi
        if cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
            cw_say_err "[エラー] ログの取得を拒否されました: $(cw_aws_err_summary)"
            return 3
        fi
        cw_say_err "[AWS エラー] $(cw_aws_err_summary)"
        return 1
    done
    cw_say_err "[AWS エラー] スロットリングが解消しませんでした: $group"
    return 1
}

# --- insights エンジン ------------------------------------------------------
cw_fetch_via_insights() {
    local group=$1 start_ms=$2 end_ms=$3 limit=$4 pattern=$5 stream=$6 raw=$7
    local out="$CW_TMPDIR/insights.json"
    local query_limit=$limit
    ((query_limit > 10000)) && query_limit=10000

    local query="fields @timestamp, @message, @logStream"
    if [[ -n $stream ]]; then
        local esc_stream=${stream//\\/\\\\}
        esc_stream=${esc_stream//\"/\\\"}
        query+=" | filter @logStream = \"$esc_stream\""
    fi
    if [[ -n $pattern ]]; then
        local escaped=${pattern//\\/\\\\}
        escaped=${escaped//\"/\\\"}
        query+=" | filter @message like \"$escaped\""
    fi
    query+=" | sort @timestamp desc | limit $query_limit"

    local rc=0
    cw_aws_run "$out" logs start-query \
        --log-group-name "$group" \
        --start-time $((start_ms / 1000)) \
        --end-time $((end_ms / 1000)) \
        --query-string "$query" \
        --limit "$query_limit" || rc=$?
    if ((rc != 0)); then
        if cw_aws_err_matches 'ResourceNotFoundException'; then
            cw_say_err "[エラー] ロググループが存在しません: $group"
            return 4
        fi
        if cw_aws_err_matches "$CW_RE_NO_PERMISSION"; then
            cw_say_err "[エラー] Logs Insights の実行を拒否されました: $(cw_aws_err_summary)"
            return 3
        fi
        cw_say_err "[AWS エラー] $(cw_aws_err_summary)"
        return 1
    fi

    local query_id
    query_id=$(jq -r '.queryId // ""' "$out")
    if [[ -z $query_id ]]; then
        cw_say_err "[エラー] Logs Insights のクエリ ID を取得できませんでした。"
        return 1
    fi

    local waited=0 max_wait=180 status="" scanned=0
    while :; do
        rc=0
        cw_aws_run "$out" logs get-query-results --query-id "$query_id" || rc=$?
        if ((rc != 0)); then
            cw_say_err "[AWS エラー] $(cw_aws_err_summary)"
            return 1
        fi
        status=$(jq -r '.status // ""' "$out")
        case $status in
            Complete|Failed|Cancelled|Timeout) break ;;
        esac
        if ((waited >= max_wait)); then
            cw_aws_run "$CW_TMPDIR/stopquery.json" logs stop-query --query-id "$query_id" >/dev/null 2>&1 || :
            cw_say_err "[エラー] Logs Insights クエリがタイムアウトしました (${max_wait}秒)"
            return 1
        fi
        scanned=$(jq -r '.statistics.recordsScanned // 0 | floor | tostring' "$out")
        cw_progress "Insights 実行中... (${scanned} 件走査 / ${waited}s)"
        sleep 1
        waited=$((waited + 1))
    done

    if [[ $status != Complete ]]; then
        cw_say_err "[エラー] Logs Insights クエリが失敗しました (status=$status)"
        return 1
    fi

    # @timestamp は 'YYYY-MM-DD HH:MM:SS.mmm' (UTC)
    jq -r '
        .results[]?
        | ( reduce .[] as $f ({}; .[$f.field] = $f.value) )
        | [ (.["@timestamp"] // ""), (.["@logStream"] // ""), ((.["@message"] // "") | sub("\n+$"; "")) ]
        | @tsv
    ' "$out" \
        | awk -F'\t' -v OFS='\t' '
            {
                ts = $1
                gsub(/[-:]/, " ", ts)
                gsub(/\./, " ", ts)
                n = split(ts, p, /[ ]+/)
                if (n >= 6) {
                    epoch = mktime(sprintf("%s %s %s %s %s %s", p[1], p[2], p[3], p[4], p[5], p[6]), 1)
                    ms = (n >= 7) ? p[7] + 0 : 0
                    $1 = (epoch < 0) ? 0 : (epoch * 1000 + ms)
                } else {
                    $1 = 0
                }
                print
            }
        ' >> "$raw"
    return 0
}

# epoch ミリ秒 -> 'MM/DD HH:MM' (進捗表示用)
cw_fmt_short() {
    cw_tzrun date -d "@$(( $1 / 1000 ))" '+%m/%d %H:%M' 2>/dev/null
}
