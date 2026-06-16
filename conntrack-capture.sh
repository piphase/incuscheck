#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

require_linux
require_cmd "$INCUS_BIN"
require_cmd "$PYTHON_BIN"
require_cmd "$CONNTRACK_BIN"
ensure_dirs

SEEN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
DAY_KEY="$(date '+%Y-%m-%d')"
HISTORY_FILE="$(history_file_for_date "$DAY_KEY")"
TMP_DIR="$(mktemp -d)"
IP_MAP_FILE="$TMP_DIR/ip_map.tsv"
RAW_FLOW_FILE="$TMP_DIR/raw_flows.tsv"
OUTPUT_FILE="$TMP_DIR/output.tsv"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

build_ip_map() {
    incus_running_ip_map_tsv | sort -u > "$IP_MAP_FILE"
}

collect_conntrack_lines() {
    : > "$RAW_FLOW_FILE"

    for family in ipv4 ipv6; do
        if run_conntrack -L -f "$family" -o extended 2>/dev/null | awk -v family="$family" '
            {
                proto = $1
                state = ""
                tuple_field = 0

                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^(ESTABLISHED|SYN_SENT|SYN_RECV|FIN_WAIT|CLOSE_WAIT|LAST_ACK|TIME_WAIT|CLOSE|LISTEN)$/ && state == "") {
                        state = $i
                        continue
                    }

                    if ($i ~ /^\[(UNREPLIED|ASSURED)\]$/) {
                        flag = $i
                        gsub(/^\[/, "", flag)
                        gsub(/\]$/, "", flag)
                        if (state == "") {
                            state = flag
                        } else if (state !~ flag) {
                            state = state "," flag
                        }
                        continue
                    }

                    if ($i ~ /^(src|dst|sport|dport)=/) {
                        split($i, kv, "=")
                        tuple_field++
                        tuple = int((tuple_field - 1) / 4) + 1
                        flow[tuple, kv[1]] = kv[2]
                    }
                }

                if (flow[1, "src"] != "" && flow[1, "dst"] != "" && flow[2, "src"] != "" && flow[2, "dst"] != "") {
                    if (state == "") {
                        state = "NONE"
                    }
                    print family "\t" proto "\t" state "\t" \
                          flow[1, "src"] "\t" flow[1, "dst"] "\t" flow[1, "sport"] "\t" flow[1, "dport"] "\t" \
                          flow[2, "src"] "\t" flow[2, "dst"] "\t" flow[2, "sport"] "\t" flow[2, "dport"]
                }

                delete flow
            }
        ' >> "$RAW_FLOW_FILE"; then
            :
        fi
    done
}

lookup_instance_by_ip() {
    local ip=$1
    awk -F'\t' -v ip="$ip" '$4 == ip { print $1 "\t" $2; exit }' "$IP_MAP_FILE"
}

should_capture_direction() {
    local direction=$1

    case "$CAPTURE_DIRECTION" in
        all)
            return 0
            ;;
        ingress)
            [[ "$direction" == "ingress" ]]
            ;;
        egress)
            [[ "$direction" == "egress" ]]
            ;;
        *)
            return 0
            ;;
    esac
}

append_row_if_allowed() {
    local instance_name=$1
    local instance_type=$2
    local direction=$3
    local protocol=$4
    local local_ip=$5
    local local_port=$6
    local remote_ip=$7
    local remote_port=$8
    local peer_instance=$9
    local state=${10}
    local country_code country_name region_name city_name isp_name org_name key

    should_capture_direction "$direction" || return

    if [[ -n "$EXCLUDE_SRC_CIDRS" ]] && [[ "$direction" == "ingress" ]]; then
        if ip_in_cidr_csv "$remote_ip" "$EXCLUDE_SRC_CIDRS"; then
            return
        fi
    fi

    if [[ -n "$EXCLUDE_DST_CIDRS" ]] && [[ "$direction" == "egress" ]]; then
        if ip_in_cidr_csv "$remote_ip" "$EXCLUDE_DST_CIDRS"; then
            return
        fi
    fi

    IFS=$'\t' read -r country_code country_name region_name city_name isp_name org_name <<<"$(lookup_geo_details "$remote_ip")"

    if [[ -n "$INCLUDE_COUNTRY_CODES" && "$(normalize_csv_list "$INCLUDE_COUNTRY_CODES")" != "ALL" ]]; then
        local normalized_includes
        normalized_includes="$(normalize_csv_list "$INCLUDE_COUNTRY_CODES")"
        if [[ ",$normalized_includes," != *",$country_code,"* ]]; then
            return
        fi
    fi

    key="$instance_name|$direction|$protocol|$local_ip|$local_port|$remote_ip|$remote_port|$state"
    if [[ -n "${SEEN_ROWS[$key]:-}" ]]; then
        return
    fi
    SEEN_ROWS["$key"]=1

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SEEN_AT" \
        "$instance_name" \
        "$instance_type" \
        "$direction" \
        "$protocol" \
        "$local_ip" \
        "$local_port" \
        "$remote_ip" \
        "$remote_port" \
        "$peer_instance" \
        "$country_code" \
        "$country_name" \
        "$region_name" \
        "$city_name" \
        "$isp_name" \
        "$org_name" \
        "$state" >> "$OUTPUT_FILE"
}

materialize_rows() {
    declare -gA SEEN_ROWS=()
    : > "$OUTPUT_FILE"

    while IFS=$'\t' read -r family protocol state orig_src orig_dst orig_sport orig_dport reply_src reply_dst reply_sport reply_dport; do
        local src_meta dst_meta reply_src_meta
        local src_name src_type dst_name dst_type reply_src_name reply_src_type

        src_meta="$(lookup_instance_by_ip "$orig_src" || true)"
        dst_meta="$(lookup_instance_by_ip "$orig_dst" || true)"
        reply_src_meta="$(lookup_instance_by_ip "$reply_src" || true)"

        src_name=""
        src_type=""
        dst_name=""
        dst_type=""
        reply_src_name=""
        reply_src_type=""

        if [[ -n "$src_meta" ]]; then
            IFS=$'\t' read -r src_name src_type <<<"$src_meta"
            append_row_if_allowed \
                "$src_name" \
                "$src_type" \
                "egress" \
                "$protocol" \
                "$orig_src" \
                "${orig_sport:-0}" \
                "$orig_dst" \
                "${orig_dport:-0}" \
                "${dst_meta%%$'\t'*}" \
                "$state"
        fi

        if [[ -n "$dst_meta" ]]; then
            IFS=$'\t' read -r dst_name dst_type <<<"$dst_meta"
            append_row_if_allowed \
                "$dst_name" \
                "$dst_type" \
                "ingress" \
                "$protocol" \
                "$orig_dst" \
                "${orig_dport:-0}" \
                "$orig_src" \
                "${orig_sport:-0}" \
                "${src_meta%%$'\t'*}" \
                "$state"
        elif [[ -n "$reply_src_meta" ]]; then
            IFS=$'\t' read -r reply_src_name reply_src_type <<<"$reply_src_meta"
            append_row_if_allowed \
                "$reply_src_name" \
                "$reply_src_type" \
                "ingress" \
                "$protocol" \
                "$reply_src" \
                "${reply_sport:-0}" \
                "$orig_src" \
                "${orig_sport:-0}" \
                "${src_meta%%$'\t'*}" \
                "$state"
        fi
    done < "$RAW_FLOW_FILE"
}

flush_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        printf 'seen_at\tinstance_name\tinstance_type\tdirection\tprotocol\tlocal_ip\tlocal_port\tremote_ip\tremote_port\tpeer_instance\tcountry_code\tcountry_name\tregion_name\tcity_name\tisp_name\torg_name\tstate\n' > "$HISTORY_FILE"
    fi

    if [[ -s "$OUTPUT_FILE" ]]; then
        cat "$OUTPUT_FILE" >> "$HISTORY_FILE"
    fi
}

print_summary() {
    local count=0

    if [[ -s "$OUTPUT_FILE" ]]; then
        count="$(wc -l < "$OUTPUT_FILE" | tr -d ' ')"
    fi

    printf '采集时间: %s\n' "$SEEN_AT"
    printf '历史文件: %s\n' "$HISTORY_FILE"
    printf '新增记录: %s\n' "$count"
    printf 'GeoIP 状态: %s' "$(geoip_status_text)"
}

build_ip_map
collect_conntrack_lines
materialize_rows
flush_history
print_summary
