#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

prompt() {
    local label=$1
    local default_value=${2:-}
    local value

    if [[ -n "$default_value" ]]; then
        read -r -p "$label [$default_value]: " value
        value="${value:-$default_value}"
    else
        read -r -p "$label: " value
    fi

    printf '%s' "$value"
}

pause_screen() {
    echo
    read -r -p "按回车继续..." _
}

print_header() {
    clear 2>/dev/null || true
    echo "${BOLD}${BLUE}incuscheck 交互菜单${RESET}"
    echo "------------------------------------------------------"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "该操作需要 root 权限，请使用 sudo 运行。"
}

status_text() {
    require_systemd

    if ! service_unit_installed; then
        printf '未安装'
        return
    fi

    if systemctl_quiet is-active "$TIMER_NAME"; then
        printf '已安装且正在运行'
    elif systemctl_quiet is-enabled "$TIMER_NAME"; then
        printf '已安装但未运行'
    else
        printf '已安装但未启用'
    fi
}

write_service_unit() {
    cat > "$SERVICE_UNIT_PATH" <<EOF
[Unit]
Description=incuscheck conntrack capture
After=network-online.target incus.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/conntrack-capture.sh
Environment=INCUSCHECK_CONFIG=$SYSTEM_CONFIG_FILE
EOF
}

write_timer_unit() {
    cat > "$TIMER_UNIT_PATH" <<EOF
[Unit]
Description=incuscheck periodic capture timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=${CAPTURE_INTERVAL_MINUTES}min
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF
}

install_runtime_files() {
    require_root

    mkdir -p "$INSTALL_DIR" "$SYSTEM_CONFIG_DIR"
    cp "$PROJECT_ROOT/checklist.sh" "$INSTALL_DIR/checklist.sh"
    cp "$PROJECT_ROOT/conntrack-capture.sh" "$INSTALL_DIR/conntrack-capture.sh"
    cp "$PROJECT_ROOT/conntrack-report.sh" "$INSTALL_DIR/conntrack-report.sh"
    cp "$PROJECT_ROOT/incuscheck.sh" "$INSTALL_DIR/incuscheck.sh"
    mkdir -p "$INSTALL_DIR/lib"
    cp "$PROJECT_ROOT/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
    chmod +x \
        "$INSTALL_DIR/checklist.sh" \
        "$INSTALL_DIR/conntrack-capture.sh" \
        "$INSTALL_DIR/conntrack-report.sh" \
        "$INSTALL_DIR/incuscheck.sh" \
        "$INSTALL_DIR/lib/common.sh"
    ln -sf "$INSTALL_DIR/incuscheck.sh" "$BIN_LINK_PATH"
}

install_or_reinstall() {
    require_linux
    require_systemd
    ensure_dirs

    echo "准备安装/重装自动 IP 记录。"

    CAPTURE_INTERVAL_MINUTES="$(prompt '采集间隔(分钟)' "$CAPTURE_INTERVAL_MINUTES")"
    [[ "$CAPTURE_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || die "采集间隔必须是数字"

    CAPTURE_DIRECTION="$(trim_spaces "$(prompt '记录方向(all/ingress/egress)' "$CAPTURE_DIRECTION")")"
    case "$CAPTURE_DIRECTION" in
        all|ingress|egress) ;;
        *) die "记录方向必须是 all/ingress/egress" ;;
    esac

    RETENTION_DAYS="$(prompt '保留天数' "$RETENTION_DAYS")"
    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "保留天数必须是数字"

    EXCLUDE_SRC_CIDRS="$(trim_spaces "$(prompt '排除来源 CIDR(逗号分隔，可留空)' "$EXCLUDE_SRC_CIDRS")")"
    EXCLUDE_DST_CIDRS="$(trim_spaces "$(prompt '排除目标 CIDR(逗号分隔，可留空)' "$EXCLUDE_DST_CIDRS")")"
    EXCLUDE_COUNTRY_CODES="$(normalize_csv_list "$(prompt '排除国家/地区代码(逗号分隔，可留空)' "$EXCLUDE_COUNTRY_CODES")")"
    INCUS_PROJECT="$(trim_spaces "$(prompt 'Incus project(留空表示默认/全部可见范围)' "$INCUS_PROJECT")")"

    require_root
    if [[ "$DATA_DIR" == "$PROJECT_ROOT/data" ]]; then
        DATA_DIR="/var/lib/incuscheck"
        HISTORY_DIR="$DATA_DIR/history"
        CACHE_DIR="$DATA_DIR/cache"
        RUNTIME_DIR="$DATA_DIR/runtime"
        LOG_DIR="$DATA_DIR/logs"
    fi
    ensure_commands_installed "$INCUS_BIN" "$CONNTRACK_BIN" "$PYTHON_BIN" "$JQ_BIN"

    if ensure_geoip_ready; then
        echo "${GREEN}GeoIP 已就绪: $GEOIP_DB_PATH${RESET}"
    else
        echo "${YELLOW}未检测到可用 GeoIP 数据库，地区过滤功能将暂不可用。${RESET}"
    fi

    install_runtime_files
    write_config_file "$SYSTEM_CONFIG_FILE"
    ACTIVE_CONFIG_FILE="$SYSTEM_CONFIG_FILE"

    write_service_unit
    write_timer_unit
    "$SYSTEMCTL_BIN" daemon-reload
    "$SYSTEMCTL_BIN" enable --now "$TIMER_NAME"
    "$SYSTEMCTL_BIN" start "$TIMER_NAME"

    echo
    echo "${GREEN}安装/重装完成。${RESET}"
    echo "状态: $(status_text)"
    echo "程序目录: $INSTALL_DIR"
    echo "命令入口: $BIN_LINK_PATH"
    if command -v "$JQ_BIN" >/dev/null 2>&1; then
        echo "可选依赖 jq: 已安装"
    else
        echo "可选依赖 jq: 未安装"
    fi
    echo "GeoIP 状态: $(geoip_status_text)"
}

show_status() {
    require_linux
    require_systemd

    print_header
    echo "${BOLD}安装与运行状态${RESET}"
    echo "主状态: $(status_text)"
    echo "GeoIP: $(geoip_status_text)"
    echo "数据目录: $DATA_DIR"
    echo "配置文件: ${ACTIVE_CONFIG_FILE:-$SYSTEM_CONFIG_FILE}"
    echo "安装目录: $INSTALL_DIR"
    echo "命令入口: $BIN_LINK_PATH"
    echo "------------------------------------------------------"

    if service_unit_installed; then
        echo "[service]"
        "$SYSTEMCTL_BIN" --no-pager --full status "$SERVICE_NAME" || true
        echo
        echo "[timer]"
        "$SYSTEMCTL_BIN" --no-pager --full status "$TIMER_NAME" || true
        echo
        echo "[最近日志]"
        "$JOURNALCTL_BIN" -u "$SERVICE_NAME" -n 50 --no-pager || true
    else
        echo "当前未安装 systemd 单元。"
    fi
}

config_env_prefix() {
    if [[ -n "${ACTIVE_CONFIG_FILE:-}" ]]; then
        printf '%s' "$ACTIVE_CONFIG_FILE"
    elif [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
        printf '%s' "$SYSTEM_CONFIG_FILE"
    else
        printf '%s' "$LOCAL_CONFIG_FILE"
    fi
}

report_marker_file() {
    local name=$1
    ensure_dirs
    printf '%s/%s.marker\n' "$RUNTIME_DIR" "$name"
}

run_report_shortcut() {
    local mode=$1
    local active_config
    active_config="$(config_env_prefix)"
    case "$mode" in
        china_ingress)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --china-ingress --group-by src --limit 50
            ;;
        china_ingress_by_instance)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --china-ingress --direction ingress --group-by instance --limit 50
            ;;
        instance_summary)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --group-by instance --limit 50
            ;;
        source_summary)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --group-by src --limit 50
            ;;
        top_sources)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --top-sources --limit 20
            ;;
        destination_summary)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --group-by dst --limit 50
            ;;
        details)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --details --limit 100
            ;;
    esac
}

show_ip_statistics() {
    local choice instance_name days_input country_code direction_input marker_file
    local active_config
    active_config="$(config_env_prefix)"

    print_header
    echo "${BOLD}IP 统计数据${RESET}"
    echo "1. 按容器聚合"
    echo "2. 按来源 IP 聚合"
    echo "3. 按目标 IP 聚合"
    echo "4. 只看中国大陆入站来源"
    echo "5. 按容器查看中国大陆入站"
    echo "6. 最近新增中国大陆来源"
    echo "7. 来源 IP Top N"
    echo "8. 查看指定容器明细"
    echo "9. 自定义国家/地区过滤"
    echo "0. 返回"
    echo "------------------------------------------------------"
    read -r -p "请选择: " choice

    case "$choice" in
        1)
            run_report_shortcut instance_summary
            ;;
        2)
            run_report_shortcut source_summary
            ;;
        3)
            run_report_shortcut destination_summary
            ;;
        4)
            run_report_shortcut china_ingress
            ;;
        5)
            run_report_shortcut china_ingress_by_instance
            ;;
        6)
            marker_file="$(report_marker_file china_ingress_recent)"
            if [[ -f "$marker_file" ]]; then
                INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --china-ingress --since-file "$marker_file" --group-by src --limit 50
            else
                INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --china-ingress --group-by src --limit 50
            fi
            touch "$marker_file"
            ;;
        7)
            run_report_shortcut top_sources
            ;;
        8)
            instance_name="$(prompt '输入实例名')"
            days_input="$(prompt '查看最近几天' "$DEFAULT_REPORT_DAYS")"
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --details --instance "$instance_name" --days "$days_input" --limit 200
            ;;
        9)
            country_code="$(normalize_csv_list "$(prompt '输入国家/地区代码，例如 CN,US')")"
            direction_input="$(prompt '方向(all/ingress/egress)' "all")"
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-report.sh" --country "$country_code" --direction "$direction_input" --group-by src --limit 100
            ;;
        0)
            return
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

show_process_review() {
    local choice
    local active_config
    active_config="$(config_env_prefix)"

    print_header
    echo "${BOLD}进程审查${RESET}"
    echo "1. 全局进程视图"
    echo "2. 按容器分类视图"
    echo "0. 返回"
    echo "------------------------------------------------------"
    read -r -p "请选择: " choice

    case "$choice" in
        1)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/checklist.sh" global
            ;;
        2)
            INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/checklist.sh" all
            ;;
        0)
            return
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

cleanup_history_data() {
    local choice file kept_days used country_code instance_name marker_file

    print_header
    echo "${BOLD}清理 IP 记录数据${RESET}"
    echo "1. 清理入站记录"
    echo "2. 清理出站记录"
    echo "3. 清理全部记录"
    echo "4. 仅保留最近 N 天"
    echo "5. 按国家代码清理"
    echo "6. 按容器清理"
    echo "7. 查看当前数据占用"
    echo "0. 返回"
    echo "------------------------------------------------------"
    read -r -p "请选择: " choice

    case "$choice" in
        1|2)
            for file in "$HISTORY_DIR"/*.tsv; do
                [[ -f "$file" ]] || continue
                awk -F'\t' -v wanted="$([[ "$choice" == "1" ]] && echo ingress || echo egress)" 'NR == 1 || $4 != wanted' "$file" > "$file.tmp"
                mv "$file.tmp" "$file"
            done
            echo "已清理指定方向记录。"
            ;;
        3)
            rm -f "$HISTORY_DIR"/*.tsv
            rm -f "$(geoip_cache_file)"
            echo "已清理全部历史记录。"
            ;;
        4)
            kept_days="$(prompt '保留最近几天' "$RETENTION_DAYS")"
            [[ "$kept_days" =~ ^[0-9]+$ ]] || die "必须输入数字"
            find "$HISTORY_DIR" -type f -name '*.tsv' -mtime +"$kept_days" -delete
            echo "已清理 $kept_days 天之前的记录。"
            ;;
        5)
            country_code="$(normalize_csv_list "$(prompt '输入国家/地区代码，例如 CN,US')")"
            for file in "$HISTORY_DIR"/*.tsv; do
                [[ -f "$file" ]] || continue
                awk -F'\t' -v wanted="$country_code" '
                    function in_csv(value, csv,    n, items, i) {
                        n = split(csv, items, ",")
                        for (i = 1; i <= n; i++) {
                            if (items[i] == value) return 1
                        }
                        return 0
                    }
                    NR == 1 || !in_csv($11, wanted)
                ' "$file" > "$file.tmp"
                mv "$file.tmp" "$file"
            done
            marker_file="$(report_marker_file china_ingress_recent)"
            rm -f "$marker_file"
            echo "已清理国家/地区 $country_code 的记录。"
            ;;
        6)
            instance_name="$(prompt '输入容器名')"
            for file in "$HISTORY_DIR"/*.tsv; do
                [[ -f "$file" ]] || continue
                awk -F'\t' -v wanted="$instance_name" 'NR == 1 || $2 != wanted' "$file" > "$file.tmp"
                mv "$file.tmp" "$file"
            done
            echo "已清理容器 $instance_name 的记录。"
            ;;
        7)
            used="$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')"
            echo "当前数据占用: ${used:-0}"
            ;;
        0)
            return
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

modify_config() {
    print_header
    echo "${BOLD}修改配置${RESET}"

    CAPTURE_INTERVAL_MINUTES="$(prompt '采集间隔(分钟)' "$CAPTURE_INTERVAL_MINUTES")"
    CAPTURE_DIRECTION="$(trim_spaces "$(prompt '记录方向(all/ingress/egress)' "$CAPTURE_DIRECTION")")"
    EXCLUDE_SRC_CIDRS="$(trim_spaces "$(prompt '排除来源 CIDR' "$EXCLUDE_SRC_CIDRS")")"
    EXCLUDE_DST_CIDRS="$(trim_spaces "$(prompt '排除目标 CIDR' "$EXCLUDE_DST_CIDRS")")"
    EXCLUDE_COUNTRY_CODES="$(normalize_csv_list "$(prompt '排除国家/地区代码' "$EXCLUDE_COUNTRY_CODES")")"
    RETENTION_DAYS="$(prompt '保留天数' "$RETENTION_DAYS")"
    DEFAULT_REPORT_DAYS="$(prompt '默认统计天数' "$DEFAULT_REPORT_DAYS")"
    require_root
    write_config_file "$SYSTEM_CONFIG_FILE"

    if service_unit_installed; then
        write_timer_unit
        "$SYSTEMCTL_BIN" daemon-reload
        "$SYSTEMCTL_BIN" restart "$TIMER_NAME"
    fi

    echo "配置已保存。"
}

uninstall_everything() {
    require_linux
    require_systemd

    print_header
    echo "${RED}${BOLD}彻底卸载${RESET}"
    echo "这会删除本工具自己的脚本配置、systemd 单元和历史数据。"
    echo "不会卸载系统依赖，也不会修改 Incus 本身配置。"
    echo "------------------------------------------------------"

    local confirm
    confirm="$(prompt '请输入 UNINSTALL 以确认')"
    if [[ "$confirm" != "UNINSTALL" ]]; then
        echo "已取消。"
        return
    fi

    require_root

    if service_unit_installed; then
        "$SYSTEMCTL_BIN" disable --now "$TIMER_NAME" || true
        "$SYSTEMCTL_BIN" stop "$SERVICE_NAME" || true
        rm -f "$SERVICE_UNIT_PATH" "$TIMER_UNIT_PATH"
        "$SYSTEMCTL_BIN" daemon-reload
    fi

    rm -f "$SYSTEM_CONFIG_FILE" "$BIN_LINK_PATH"
    rmdir "$SYSTEM_CONFIG_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -rf "$DATA_DIR"

    echo "${GREEN}卸载完成。${RESET}"
}

handle_hidden_command() {
    local active_config
    active_config="$(config_env_prefix)"
    case "${1:-}" in
        --run-once)
            exec env INCUSCHECK_CONFIG="$active_config" "$PROJECT_ROOT/conntrack-capture.sh"
            ;;
        --debug-status)
            show_status
            exit 0
            ;;
    esac
}

main_menu() {
    local choice

    while true; do
        print_header
        echo "1. 安装/重装自动 IP 记录"
        echo "2. 查看安装与运行状态"
        echo "3. 查看 IP 统计数据"
        echo "4. 进程审查"
        echo "5. 清理 IP 记录数据"
        echo "6. 修改配置"
        echo "${RED}99. 彻底卸载${RESET}"
        echo "0. 退出"
        echo "------------------------------------------------------"
        read -r -p "请选择: " choice

        case "$choice" in
            1)
                install_or_reinstall
                pause_screen
                ;;
            2)
                show_status
                pause_screen
                ;;
            3)
                show_ip_statistics
                pause_screen
                ;;
            4)
                show_process_review
                pause_screen
                ;;
            5)
                cleanup_history_data
                pause_screen
                ;;
            6)
                modify_config
                pause_screen
                ;;
            99)
                uninstall_everything
                pause_screen
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选择"
                pause_screen
                ;;
        esac
    done
}

handle_hidden_command "${1:-}"
main_menu
