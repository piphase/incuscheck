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
  all        同时展示宿主机 cgroup 视角和按容器分类视角
  host       只看宿主机全局视角
  instances  只看按容器分类视角
  global     全局进程视图，统计过滤后的第三方进程出现次数
EOF
}

collect_host_process_map() {
    ps -eo pid,ppid,comm=,cgroup= | \
    awk '$1 != 2 && $2 != 2 && $3 != "" {
        cgroup=$4
        for (i=5; i<=NF; i++) cgroup=cgroup " " $i
        print $3 "|" cgroup
    }' | \
    grep -vE "^($PROCESS_IGNORE_REGEX)\|" || true
}

scan_host_cgroups() {
    echo "🔍 宿主机视角: 按 cgroup 归类业务进程"
    echo "------------------------------------------------------"

    local host_summary
    host_summary="$(collect_host_process_map)"

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
                print "🖥️  [宿主机]"
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
    echo "🔍 按容器分类视角: 从宿主机 cgroup 归属统计业务进程"
    echo "------------------------------------------------------"

    local host_summary
    host_summary="$(collect_host_process_map)"

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
            continue
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
            print "📦 [" node "]"
            last_node = node
        }
        printf "   ├── %-20s : %d\n", comm, count
    }'

    echo "------------------------------------------------------"
    echo "注: 这里完全基于宿主机 cgroup 归属统计，对容器内部无感。"
    echo "注: VM 通常只能看到宿主机侧进程归属，未必能看到客体内全部真实进程。"
}

scan_global_processes() {
    echo "🔍 全局进程视图: 统计过滤后的第三方进程出现次数和分布容器数"
    echo "------------------------------------------------------"

    local tmp_file
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' RETURN

    collect_host_process_map | \
    while IFS="|" read -r comm cgroup; do
        if [[ "$cgroup" =~ incus\.payload\.([^/]+) ]]; then
            node="${BASH_REMATCH[1]%.scope}"
        elif [[ "$cgroup" =~ lxc\.payload\.([^/]+) ]]; then
            node="${BASH_REMATCH[1]%.scope}"
        else
            continue
        fi
        printf '%s\t%s\n' "$node" "$comm"
    done > "$tmp_file"

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
        }
        END {
            for (proc in total_count) {
                print proc "\t" total_count[proc] "\t" instance_count[proc]
            }
        }
    ' "$tmp_file" | sort -t $'\t' -k2,2nr -k3,3nr | \
    awk -F'\t' '
        BEGIN {
            printf "%-24s %-8s %-10s\n", "进程名", "次数", "容器数"
            printf "%-24s %-8s %-10s\n", "------------------------", "--------", "----------"
        }
        {
            printf "%-24s %-8s %-10s\n", $1, $2, $3
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
