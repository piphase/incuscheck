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
SHOW_CONTAINER_VIEW="false"
SHOW_INGRESS_ONLY="false"

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
  --container-view         按容器分组列出详细 IP 信息
  --ingress-only           仅显示入站记录
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
        --container-view)
            SHOW_CONTAINER_VIEW="true"
            shift
            ;;
        --ingress-only)
            SHOW_INGRESS_ONLY="true"
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
        -v since_epoch="$since_epoch" \
        -v show_ingress_only="$SHOW_INGRESS_ONLY" '
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
            if (NF < 17) next
            if (since_epoch > 0 && to_epoch($1) < since_epoch) next
            if (direction_filter != "all" && $4 != direction_filter) next
            if (show_ingress_only == "true" && $4 != "ingress") next
            if (instance_filter != "" && $2 != instance_filter) next
            if (country_filter != "" && !in_csv($11, country_filter)) next
            if (only_china == "true" && !($4 == "ingress" && $11 == "CN")) next
            print
        }'
}

print_container_view() {
    local files=("$@")
    build_filtered_stream "${files[@]}" | \
    awk -F'\t' '
        function add_port(key, port) {
            token = key SUBSEP port
            if (port == "" || port == "0") return
            if (!(token in seen_port)) {
                seen_port[token] = 1
                ports[key] = (ports[key] == "" ? port : ports[key] "," port)
            }
        }
        {
            key = $2 SUBSEP $4 SUBSEP $8
            instance[key] = $2
            direction[key] = ($4 == "ingress" ? "入站" : "出站")
            remote_ip[key] = $8
            country_name[key] = ($12 == "" ? "未知" : $12)
            region_name[key] = ($13 == "" ? "未知" : $13)
            city_name[key] = ($14 == "" ? "未知" : $14)
            isp_name[key] = ($15 == "" ? "未知" : $15)
            org_name[key] = ($16 == "" ? "未知" : $16)
            count[key]++
            if (!(key in first_seen) || $1 < first_seen[key]) first_seen[key] = $1
            if (!(key in last_seen) || $1 > last_seen[key]) last_seen[key] = $1

            if ($4 == "ingress") {
                add_port(key, $7)
            } else {
                add_port(key, $9)
            }
        }
        END {
            for (key in count) {
                print instance[key] "\t" direction[key] "\t" remote_ip[key] "\t" count[key] "\t" ports[key] "\t" \
                      country_name[key] "\t" region_name[key] "\t" city_name[key] "\t" isp_name[key] "\t" org_name[key] "\t" \
                      first_seen[key] "\t" last_seen[key]
            }
        }' | sort -t $'\t' -k1,1 -k2,2 -k4,4nr -k3,3 | \
    awk -F'\t' '
        {
            if ($1 != last_instance) {
                if (last_instance != "") print ""
                printf "容器: %s\n", $1
                last_instance = $1
                last_direction = ""
            }
            if ($2 != last_direction) {
                printf "  %s:\n", $2
                last_direction = $2
            }
            printf "    - %s｜次数：%s｜端口：%s｜%s｜%s｜%s｜%s\n",
                $3, $4, ($5 == "" ? "-" : $5), $6, $7, $8, $9
        }'
}

mapfile -t files < <(collect_recent_files "$DAYS")

if [[ ${#files[@]} -eq 0 ]]; then
    die "最近 $DAYS 天没有可用历史数据。"
fi

filtered_count="$(build_filtered_stream "${files[@]}" | wc -l | tr -d ' ')"

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

if [[ "${filtered_count:-0}" -eq 0 ]]; then
    echo "当前没有符合条件的历史记录。"
    echo "如果刚安装完成，请先等待定时采集，或执行 ic --run-once 后再查看。"
    exit 0
fi

if [[ "$SHOW_CONTAINER_VIEW" == "true" ]]; then
    print_container_view "${files[@]}"
else
    print_container_view "${files[@]}"
fi
