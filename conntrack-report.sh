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
            if ("'"$SHOW_INGRESS_ONLY"'" == "true" && $4 != "ingress") next
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
        function flush_section(section_name) {
            if (section_count[section_name] > 0) {
                printf "  %s:\n", section_name
                printf "%s", section_rows[section_name]
            }
        }
        function append_row(section_name, row_text) {
            section_count[section_name]++
            section_rows[section_name] = section_rows[section_name] row_text
        }
        {
            instance = $2
            direction = ($4 == "ingress" ? "入站" : "出站")
            local_ip = $6
            local_port = $7
            remote_ip = $8
            remote_port = $9
            country_name = ($12 == "" ? "未知" : $12)
            region_name = ($13 == "" ? "未知" : $13)
            city_name = ($14 == "" ? "未知" : $14)
            isp_name = ($15 == "" ? "未知" : $15)
            org_name = ($16 == "" ? "未知" : $16)
            state = ($17 == "" ? "-" : $17)
            dedup_key = instance "|" direction "|" remote_ip "|" remote_port "|" local_ip "|" local_port "|" country_name "|" region_name "|" city_name "|" isp_name "|" org_name

            if (seen[dedup_key]++) {
                next
            }

            if (instance != last_instance) {
                if (last_instance != "") {
                    flush_section("入站")
                    flush_section("出站")
                    print ""
                    delete section_rows
                    delete section_count
                }
                printf "容器: %s\n", instance
                last_instance = instance
            }

            row = sprintf("    - 远端=%s:%s | 本地=%s:%s | 国家=%s | 省份=%s | 城市=%s | 运营商=%s | 组织=%s | 状态=%s\n",
                remote_ip, remote_port, local_ip, local_port, country_name, region_name, city_name, isp_name, org_name, state)
            append_row(direction, row)
        }
        END {
            if (last_instance != "") {
                flush_section("入站")
                flush_section("出站")
            }
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
