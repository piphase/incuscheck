#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

MODE="${1:-all}"

print_usage() {
    cat <<'EOF'
用法:
  ./checklist.sh [all|host|instances|global]

说明:
  all        同时展示宿主机 cgroup 视角和实例内进程视角
  host       只看宿主机 cgroup 视角
  instances  只看实例内进程视角（依赖 incus exec；VM 需要 incus-agent）
  global     全局进程视图，统计进程出现次数和分布实例数
EOF
}

scan_host_cgroups() {
    echo "🔍 宿主机视角: 按 cgroup 归类业务进程"
    echo "------------------------------------------------------"

    local host_summary
    host_summary="$(
        ps -eo pid,ppid,comm=,cgroup= | \
        awk '$1 != 2 && $2 != 2 && $3 != "" {
            cgroup=$4
            for (i=5; i<=NF; i++) cgroup=cgroup " " $i
            print $3 "|" cgroup
        }' | \
        grep -vE "^($PROCESS_IGNORE_REGEX)\|" || true
    )"

    if [[ -z "$host_summary" ]]; then
        echo "未发现命中过滤后的业务进程。"
        echo "------------------------------------------------------"
        return
    fi

    printf '%s\n' "$host_summary" | \
    while IFS="|" read -r comm cgroup; do
        if [[ "$cgroup" =~ incus\.payload\.([^/]+) ]]; then
            node="${BASH_REMATCH[1]%.scope}"
        elif [[ "$cgroup" =~ lxc\.payload\.([^/]+) ]]; then
            node="${BASH_REMATCH[1]%.scope}"
        else
            node="0_Host"
        fi
        echo "${node}|${comm}"
    done | \
    awk -F'|' '{ count[$1 "|" $2]++ } END { for (key in count) print key "|" count[key] }' | \
    sort -t'|' -k1,1 -k3,3nr | \
    awk -F'|' '
    BEGIN { last_node = "" }
    {
        node = $1
        comm = $2
        count = $3

        if (node != last_node) {
            if (last_node != "") print ""

            if (node == "0_Host") {
                print "🖥️  [宿主机 (Host)]"
            } else {
                print "📦 [" node "]"
            }
            last_node = node
        }
        printf "   ├── %-20s : %d\n", comm, count
    }'

    echo "------------------------------------------------------"
}

scan_instance_processes() {
    require_cmd "$INCUS_BIN"
    require_cmd "$PYTHON_BIN"

    local ps_snippet='
if command -v ps >/dev/null 2>&1; then
    ps -eo comm= 2>/dev/null || ps -A -o comm= 2>/dev/null || ps
elif command -v busybox >/dev/null 2>&1; then
    busybox ps | awk "NR > 1 { print \$5 }"
else
    exit 127
fi
'

    mapfile -t running_instances < <(incus_running_instances_tsv)

    echo "🔍 实例内视角: 通过 incus exec 统计实例中的业务进程"
    echo "------------------------------------------------------"

    if [[ ${#running_instances[@]} -eq 0 ]]; then
        echo "没有发现 Running 状态的实例。"
        echo "------------------------------------------------------"
        return
    fi

    for row in "${running_instances[@]}"; do
        IFS=$'\t' read -r instance_name instance_type <<<"$row"

        if output="$(run_incus exec "$instance_name" --mode non-interactive -- sh -c "$ps_snippet" 2>/dev/null)"; then
            printf '📦 [%s] (%s)\n' "$instance_name" "$instance_type"
            if filtered="$(
                printf '%s\n' "$output" | \
                sed 's/^ *//; s/ *$//' | \
                awk 'NF > 0 { print $0 }' | \
                grep -vE "^($PROCESS_IGNORE_REGEX)$" || true
            )" && [[ -n "$filtered" ]]; then
                printf '%s\n' "$filtered" | \
                sort | uniq -c | sort -nr | \
                awk '{ count=$1; $1=""; sub(/^ /, ""); printf "   ├── %-20s : %d\n", $0, count }'
            else
                echo "   ├── 未发现命中过滤后的业务进程"
            fi
            echo
        else
            printf '📦 [%s] (%s)\n' "$instance_name" "$instance_type"
            echo "   ├── 无法进入实例执行 ps"
            echo "   ├── 容器通常可直接执行"
            echo "   ├── VM 需要实例内 incus-agent 正常运行"
            echo
        fi
    done

    echo "------------------------------------------------------"
}

scan_global_processes() {
    require_cmd "$INCUS_BIN"
    require_cmd "$PYTHON_BIN"

    local ps_snippet='
if command -v ps >/dev/null 2>&1; then
    ps -eo comm= 2>/dev/null || ps -A -o comm= 2>/dev/null || ps
elif command -v busybox >/dev/null 2>&1; then
    busybox ps | awk "NR > 1 { print \$5 }"
else
    exit 127
fi
'

    local tmp_file
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' RETURN

    echo "🔍 全局进程视图: 统计进程出现次数和分布实例"
    echo "------------------------------------------------------"

    while IFS= read -r proc_name; do
        printf '0_Host\t%s\n' "$proc_name" >> "$tmp_file"
    done < <(
        ps -eo comm= | \
        sed 's/^ *//; s/ *$//' | \
        awk 'NF > 0 { print }' | \
        grep -vE "^($PROCESS_IGNORE_REGEX)$" || true
    )

    mapfile -t running_instances < <(incus_running_instances_tsv)

    local row instance_name instance_type output filtered
    for row in "${running_instances[@]}"; do
        IFS=$'\t' read -r instance_name instance_type <<<"$row"
        if output="$(run_incus exec "$instance_name" --mode non-interactive -- sh -c "$ps_snippet" 2>/dev/null)"; then
            filtered="$(
                printf '%s\n' "$output" | \
                sed 's/^ *//; s/ *$//' | \
                awk 'NF > 0 { print $0 }' | \
                grep -vE "^($PROCESS_IGNORE_REGEX)$" || true
            )"
            if [[ -n "$filtered" ]]; then
                while IFS= read -r proc_name; do
                    [[ -n "$proc_name" ]] || continue
                    printf '%s\t%s\n' "$instance_name" "$proc_name" >> "$tmp_file"
                done <<<"$filtered"
            fi
        fi
    done

    if [[ ! -s "$tmp_file" ]]; then
        echo "未发现命中过滤后的业务进程。"
        echo "------------------------------------------------------"
        return
    fi

    awk -F'\t' '
        function mark_instance(proc, instance) {
            token = proc SUBSEP instance
            if (!(token in seen)) {
                seen[token] = 1
                instance_count[proc]++
            }
        }
        {
            proc = $2
            instance = $1
            total_count[proc]++
            mark_instance(proc, instance)
            if (instance == "0_Host") {
                host_seen[proc] = "yes"
            }
        }
        END {
            for (proc in total_count) {
                host_text = (host_seen[proc] == "yes" ? "yes" : "no")
                print proc "\t" total_count[proc] "\t" instance_count[proc] "\t" host_text
            }
        }
    ' "$tmp_file" | sort -t $'\t' -k2,2nr -k3,3nr | \
    awk -F'\t' '
        BEGIN {
            printf "%-24s %-8s %-10s %-8s\n", "进程名", "次数", "实例数", "宿主机"
            printf "%-24s %-8s %-10s %-8s\n", "------------------------", "--------", "----------", "--------"
        }
        {
            printf "%-24s %-8s %-10s %-8s\n", $1, $2, $3, $4
        }
    '

    echo "------------------------------------------------------"
}

case "$MODE" in
    all)
        scan_host_cgroups
        echo
        scan_instance_processes
        ;;
    global)
        scan_global_processes
        ;;
    host)
        scan_host_cgroups
        ;;
    instances)
        scan_instance_processes
        ;;
    -h|--help|help)
        print_usage
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
