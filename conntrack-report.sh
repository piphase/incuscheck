#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs

DAYS="${DEFAULT_REPORT_DAYS:-7}"
GROUP_BY="instance"
DIRECTION="all"
COUNTRY_FILTER=""
INSTANCE_FILTER=""
LIMIT="${DEFAULT_REPORT_LIMIT:-30}"
ONLY_MAINLAND_CHINA="false"
SHOW_DETAILS="false"
SINCE_FILE=""
TOP_SOURCES="false"

usage() {
    cat <<'EOF'
用法:
  ./conntrack-report.sh [选项]

选项:
  --days N                 查看最近 N 天
  --group-by FIELD         instance|src|dst|country
  --direction MODE         ingress|egress|all
  --country CODE           只看指定国家/地区代码
  --instance NAME          只看指定实例
  --limit N                最多显示多少行
  --china-ingress          快捷视图: 中国大陆入站来源
  --details                显示明细而不是聚合
  --since-file PATH        只统计在指定文件修改时间之后新增的记录
  --top-sources            显示来源 IP Top N
  -h, --help               查看帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            DAYS="${2:-}"
            shift 2
            ;;
        --group-by)
            GROUP_BY="${2:-}"
            shift 2
            ;;
        --direction)
            DIRECTION="${2:-}"
            shift 2
            ;;
        --country)
            COUNTRY_FILTER="$(normalize_csv_list "${2:-}")"
            shift 2
            ;;
        --instance)
            INSTANCE_FILTER="${2:-}"
            shift 2
            ;;
        --limit)
            LIMIT="${2:-}"
            shift 2
            ;;
        --china-ingress)
            ONLY_MAINLAND_CHINA="true"
            shift
            ;;
        --details)
            SHOW_DETAILS="true"
            shift
            ;;
        --since-file)
            SINCE_FILE="${2:-}"
            shift 2
            ;;
        --top-sources)
            TOP_SOURCES="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数: $1"
            ;;
    esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days 必须是数字"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit 必须是数字"

collect_recent_files() {
    local days=$1
    local files=()
    local offset day_key history_file

    for (( offset=0; offset<days; offset++ )); do
        day_key="$(date -d "$offset days ago" '+%Y-%m-%d' 2>/dev/null || true)"
        if [[ -z "$day_key" ]]; then
            day_key="$(python3 - "$offset" <<'PY'
from datetime import datetime, timedelta
import sys
print((datetime.now() - timedelta(days=int(sys.argv[1]))).strftime("%Y-%m-%d"))
PY
)"
        fi
        history_file="$(history_file_for_date "$day_key")"
        [[ -f "$history_file" ]] && files+=("$history_file")
    done

    printf '%s\n' "${files[@]}"
}

readable_country_name() {
    local code=$1

    case "$code" in
        CN)
            printf 'China'
            ;;
        PRIVATE)
            printf 'Private'
            ;;
        UNKNOWN|"")
            printf 'Unknown'
            ;;
        *)
            printf '%s' "$code"
            ;;
    esac
}

build_filtered_stream() {
    local files=("$@")
    local file
    local since_epoch="0"

    if [[ -n "$SINCE_FILE" && -f "$SINCE_FILE" ]]; then
        since_epoch="$(stat -c %Y "$SINCE_FILE" 2>/dev/null || stat -f %m "$SINCE_FILE" 2>/dev/null || echo 0)"
    fi

    for file in "${files[@]}"; do
        awk -F'\t' 'NR > 1 { print }' "$file"
    done | \
    awk -F'\t' \
        -v direction_filter="$DIRECTION" \
        -v instance_filter="$INSTANCE_FILTER" \
        -v country_filter="$COUNTRY_FILTER" \
        -v only_china="$ONLY_MAINLAND_CHINA" \
        -v since_epoch="$since_epoch" '
        function in_csv(value, csv,    n, items, i) {
            if (csv == "") return 1
            n = split(csv, items, ",")
            for (i = 1; i <= n; i++) {
                if (items[i] == value) return 1
            }
            return 0
        }
        function to_epoch(ts,    base, epoch, cmd) {
            base = ts
            sub(/[+-][0-9]{4}$/, "", base)
            gsub(/T/, " ", base)
            cmd = "date -d \"" base "\" +%s 2>/dev/null"
            cmd | getline epoch
            close(cmd)
            return epoch + 0
        }
        {
            if (since_epoch > 0 && to_epoch($1) < since_epoch) next
            if (direction_filter != "all" && $4 != direction_filter) next
            if (instance_filter != "" && $2 != instance_filter) next
            if (country_filter != "" && !in_csv($11, country_filter)) next
            if (only_china == "true" && !($4 == "ingress" && $11 == "CN")) next
            print
        }'
}

print_details() {
    local files=("$@")
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    printf 'seen_at\tinstance\ttype\tdirection\tproto\tlocal_ip\tlocal_port\tremote_ip\tremote_port\tpeer\tcountry\tstate\n' > "$tmp"
    build_filtered_stream "${files[@]}" | \
    awk -F'\t' '{
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s (%s)\t%s\n",
            $1, $2, $3, $4, $5, $6, $7, $8, $9, ($10 == "" ? "-" : $10), $12, $11, $13
    }' | sort -r >> "$tmp"

    print_tsv_table "$tmp"
}

print_aggregate() {
    local files=("$@")
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    printf 'group\thits\tinstances\tdirections\tfirst_seen\tlast_seen\n' > "$tmp"

    build_filtered_stream "${files[@]}" | \
    awk -F'\t' -v mode="$GROUP_BY" '
        function add_csv(map, key, value) {
            if (value == "") value = "-"
            token = SUBSEP key SUBSEP value
            if (!(token in seen)) {
                seen[token] = 1
                map[key] = map[key] "," value
            }
        }
        {
            if (mode == "instance") group = $2
            else if (mode == "src") group = $4 == "ingress" ? $8 : $6
            else if (mode == "dst") group = $4 == "ingress" ? $6 : $8
            else if (mode == "country") group = $11 == "" ? "UNKNOWN" : $11
            else group = $2

            count[group]++
            if (!(group in first_seen) || $1 < first_seen[group]) first_seen[group] = $1
            if (!(group in last_seen) || $1 > last_seen[group]) last_seen[group] = $1
            add_csv(instances, group, $2)
            add_csv(directions, group, $4)
        }
        END {
            for (group in count) {
                gsub(/^,/, "", instances[group])
                gsub(/^,/, "", directions[group])
                print group "\t" count[group] "\t" instances[group] "\t" directions[group] "\t" first_seen[group] "\t" last_seen[group]
            }
        }' | sort -t $'\t' -k2,2nr -k6,6r | head -n "$LIMIT" >> "$tmp"

    print_tsv_table "$tmp"
}

print_top_sources() {
    local files=("$@")
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    printf 'source_ip\thits\tinstances\tcountries\tfirst_seen\tlast_seen\n' > "$tmp"

    build_filtered_stream "${files[@]}" | \
    awk -F'\t' '
        function add_csv(map, key, value) {
            if (value == "") value = "-"
            token = SUBSEP key SUBSEP value
            if (!(token in seen)) {
                seen[token] = 1
                map[key] = map[key] "," value
            }
        }
        {
            source = ($4 == "ingress" ? $8 : $8)
            count[source]++
            if (!(source in first_seen) || $1 < first_seen[source]) first_seen[source] = $1
            if (!(source in last_seen) || $1 > last_seen[source]) last_seen[source] = $1
            add_csv(instances, source, $2)
            add_csv(countries, source, $11)
        }
        END {
            for (source in count) {
                gsub(/^,/, "", instances[source])
                gsub(/^,/, "", countries[source])
                print source "\t" count[source] "\t" instances[source] "\t" countries[source] "\t" first_seen[source] "\t" last_seen[source]
            }
        }' | sort -t $'\t' -k2,2nr -k6,6r | head -n "$LIMIT" >> "$tmp"

    print_tsv_table "$tmp"
}

mapfile -t files < <(collect_recent_files "$DAYS")

if [[ ${#files[@]} -eq 0 ]]; then
    die "最近 $DAYS 天没有可用历史数据。"
fi

echo "📊 IP 统计数据"
echo "时间范围: 最近 $DAYS 天"
echo "方向过滤: $DIRECTION"
echo "实例过滤: ${INSTANCE_FILTER:-全部}"
if [[ "$ONLY_MAINLAND_CHINA" == "true" ]]; then
    echo "地区过滤: 中国大陆入站来源"
elif [[ -n "$COUNTRY_FILTER" ]]; then
    echo "地区过滤: $COUNTRY_FILTER"
else
    echo "地区过滤: 全部"
fi
echo "------------------------------------------------------"

if [[ "$SHOW_DETAILS" == "true" ]]; then
    print_details "${files[@]}"
elif [[ "$TOP_SOURCES" == "true" ]]; then
    print_top_sources "${files[@]}"
else
    print_aggregate "${files[@]}"
fi
