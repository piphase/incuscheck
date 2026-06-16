#!/usr/bin/env bash

COMMON_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$COMMON_SOURCE" ]]; do
    COMMON_SOURCE="$(readlink "$COMMON_SOURCE")"
done
PROJECT_ROOT="$(cd "$(dirname "$COMMON_SOURCE")/.." && pwd)"
LOCAL_CONFIG_FILE="$PROJECT_ROOT/incuscheck.conf"
SYSTEM_CONFIG_DIR="${SYSTEM_CONFIG_DIR:-/etc/incuscheck}"
SYSTEM_CONFIG_FILE="${SYSTEM_CONFIG_FILE:-$SYSTEM_CONFIG_DIR/incuscheck.conf}"
ACTIVE_CONFIG_FILE=""

if [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SYSTEM_CONFIG_FILE"
    ACTIVE_CONFIG_FILE="$SYSTEM_CONFIG_FILE"
elif [[ -f "$LOCAL_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LOCAL_CONFIG_FILE"
    ACTIVE_CONFIG_FILE="$LOCAL_CONFIG_FILE"
fi

if [[ -n "${INCUSCHECK_CONFIG:-}" && -f "${INCUSCHECK_CONFIG}" ]]; then
    # shellcheck disable=SC1090
    source "${INCUSCHECK_CONFIG}"
    ACTIVE_CONFIG_FILE="${INCUSCHECK_CONFIG}"
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/incuscheck}"
BIN_LINK_PATH="${BIN_LINK_PATH:-/usr/local/bin/incuscheck}"

DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
HISTORY_DIR="${HISTORY_DIR:-$DATA_DIR/history}"
CACHE_DIR="${CACHE_DIR:-$DATA_DIR/cache}"
RUNTIME_DIR="${RUNTIME_DIR:-$DATA_DIR/runtime}"
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"

CAPTURE_INTERVAL_MINUTES="${CAPTURE_INTERVAL_MINUTES:-2}"
CAPTURE_DIRECTION="${CAPTURE_DIRECTION:-all}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
EXCLUDE_SRC_CIDRS="${EXCLUDE_SRC_CIDRS:-}"
EXCLUDE_DST_CIDRS="${EXCLUDE_DST_CIDRS:-}"
INCLUDE_COUNTRY_CODES="${INCLUDE_COUNTRY_CODES:-CN}"
INCLUDE_LINK_LOCAL_IPV6="${INCLUDE_LINK_LOCAL_IPV6:-false}"
INCUS_PROJECT="${INCUS_PROJECT:-}"
GEOIP_DB_PATH="${GEOIP_DB_PATH:-}"
GEOIP_ENABLED="${GEOIP_ENABLED:-auto}"
GEOIP_PROVIDER="${GEOIP_PROVIDER:-auto}"
DEFAULT_REPORT_DAYS="${DEFAULT_REPORT_DAYS:-7}"
DEFAULT_REPORT_LIMIT="${DEFAULT_REPORT_LIMIT:-30}"

INCUS_BIN="${INCUS_BIN:-incus}"
CONNTRACK_BIN="${CONNTRACK_BIN:-conntrack}"
JQ_BIN="${JQ_BIN:-jq}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
MMDBLOOKUP_BIN="${MMDBLOOKUP_BIN:-mmdblookup}"
GEOIPLOOKUP_BIN="${GEOIPLOOKUP_BIN:-geoiplookup}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
JOURNALCTL_BIN="${JOURNALCTL_BIN:-journalctl}"

SERVICE_NAME="${SERVICE_NAME:-incuscheck-capture.service}"
TIMER_NAME="${TIMER_NAME:-incuscheck-capture.timer}"
SERVICE_UNIT_PATH="${SERVICE_UNIT_PATH:-/etc/systemd/system/$SERVICE_NAME}"
TIMER_UNIT_PATH="${TIMER_UNIT_PATH:-/etc/systemd/system/$TIMER_NAME}"

DEFAULT_PROCESS_IGNORE_REGEX='systemd|systemd-.*|init|supervise-daemo|dbus-daemon|polkitd|agetty|getty|lxcfs|bash|sh|ps|grep|sort|uniq|awk|sed|cut|tr|su|sudo|sshd-session|udhcpc|syslogd|rsyslogd|cron|crond|snapd|unattended-upgr|packagekitd|networkd-dispat|multipathd|incuscheck\.sh|check\.sh|checklist\.sh|\(sd-pam\)|zed|ld-musl.*|irqbalance|incushlii-audit|incushlii-agent|rfw|qemu-ga|sleep'
PROCESS_IGNORE_REGEX="${PROCESS_IGNORE_REGEX:-$DEFAULT_PROCESS_IGNORE_REGEX}"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
}

is_linux() {
    [[ "$(uname -s)" == "Linux" ]]
}

require_linux() {
    is_linux || die "该功能只能在 Linux 宿主机上运行。"
}

has_systemd() {
    command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

require_systemd() {
    has_systemd || die "当前系统未检测到 systemd，无法使用安装/状态/卸载功能。"
}

ensure_dirs() {
    mkdir -p "$DATA_DIR" "$HISTORY_DIR" "$CACHE_DIR" "$RUNTIME_DIR" "$LOG_DIR"
}

history_file_for_date() {
    local day_key=$1
    printf '%s/%s.tsv\n' "$HISTORY_DIR" "$day_key"
}

normalize_csv_list() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[[:space:]]//g; s/^,*//; s/,*$//; s/,,*/,/g'
}

trim_spaces() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

run_incus() {
    local -a cmd=("$INCUS_BIN")

    if [[ -n "$INCUS_PROJECT" ]]; then
        cmd+=(--project "$INCUS_PROJECT")
    fi

    cmd+=("$@")
    "${cmd[@]}"
}

run_incus_query() {
    local endpoint=$1
    local -a cmd=("$INCUS_BIN")

    if [[ -n "$INCUS_PROJECT" ]]; then
        if [[ "$endpoint" == *\?* ]]; then
            endpoint="${endpoint}&project=${INCUS_PROJECT}"
        else
            endpoint="${endpoint}?project=${INCUS_PROJECT}"
        fi
    fi

    cmd+=(query "$endpoint")
    "${cmd[@]}"
}

incus_running_instances_tsv() {
    local instances_json

    require_cmd "$PYTHON_BIN"
    instances_json="$(run_incus_query /1.0/instances?recursion=2)"

    INCUSCHECK_INCUS_JSON="$instances_json" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["INCUSCHECK_INCUS_JSON"])

for item in data:
    if item.get("status") not in ("Running", "RUNNING"):
        continue
    print(f"{item.get('name', '')}\t{item.get('type', 'container')}")
PY
}

incus_running_ip_map_tsv() {
    local instances_json

    require_cmd "$PYTHON_BIN"
    instances_json="$(run_incus_query /1.0/instances?recursion=2)"

    INCLUDE_LINK_LOCAL_IPV6="$INCLUDE_LINK_LOCAL_IPV6" INCUSCHECK_INCUS_JSON="$instances_json" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

include_link_local = os.environ.get("INCLUDE_LINK_LOCAL_IPV6", "false").lower() == "true"
data = json.loads(os.environ["INCUSCHECK_INCUS_JSON"])

for item in data:
    if item.get("status") not in ("Running", "RUNNING"):
        continue

    name = item.get("name", "")
    inst_type = item.get("type", "container")
    network = (item.get("state") or {}).get("network") or {}

    for iface in network.values():
        for address in iface.get("addresses", []) or []:
            family = address.get("family")
            scope = address.get("scope")
            value = address.get("address")
            if family not in ("inet", "inet6"):
                continue
            if scope == "link" and not include_link_local:
                continue
            if scope == "local":
                continue
            if value in ("127.0.0.1", "::1"):
                continue
            if not value:
                continue
            print(f"{name}\t{inst_type}\t{family}\t{value}")
PY
}

run_conntrack() {
    local -a cmd=("$CONNTRACK_BIN" "$@")

    if [[ "${EUID}" -eq 0 ]]; then
        "${cmd[@]}"
        return
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "${cmd[@]}"
        return
    fi

    die "运行 conntrack 需要 root 权限。请用 root 执行，或提前配置好无密码 sudo。"
}

detect_package_manager() {
    local candidate

    for candidate in apt-get dnf yum zypper pacman; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

command_to_package_name() {
    local manager=$1
    local command_name=$2
    command_name="$(basename "$command_name")"

    case "$manager:$command_name" in
        apt-get:incus) printf 'incus\n' ;;
        apt-get:conntrack) printf 'conntrack\n' ;;
        apt-get:python3) printf 'python3\n' ;;
        apt-get:jq) printf 'jq\n' ;;
        apt-get:mmdblookup) printf 'libmaxminddb-bin\n' ;;
        apt-get:geoiplookup) printf 'geoip-bin\n' ;;
        apt-get:geoip-database) printf 'geoip-database\n' ;;
        apt-get:geoipupdate) printf 'geoipupdate\n' ;;
        apt-get:mmdb-bin) printf 'mmdb-bin\n' ;;
        dnf:incus|yum:incus) printf 'incus\n' ;;
        dnf:conntrack|yum:conntrack) printf 'conntrack-tools\n' ;;
        dnf:python3|yum:python3) printf 'python3\n' ;;
        dnf:jq|yum:jq) printf 'jq\n' ;;
        dnf:mmdblookup|yum:mmdblookup) printf 'libmaxminddb\n' ;;
        dnf:geoiplookup|yum:geoiplookup) printf 'GeoIP\n' ;;
        dnf:geoipupdate|yum:geoipupdate) printf 'geoipupdate\n' ;;
        zypper:incus) printf 'incus\n' ;;
        zypper:conntrack) printf 'conntrack-tools\n' ;;
        zypper:python3) printf 'python3\n' ;;
        zypper:jq) printf 'jq\n' ;;
        zypper:mmdblookup) printf 'libmaxminddb-tools\n' ;;
        zypper:geoiplookup) printf 'GeoIP\n' ;;
        zypper:geoipupdate) printf 'geoipupdate\n' ;;
        pacman:incus) printf 'incus\n' ;;
        pacman:conntrack) printf 'conntrack-tools\n' ;;
        pacman:python3) printf 'python\n' ;;
        pacman:jq) printf 'jq\n' ;;
        pacman:mmdblookup) printf 'libmaxminddb\n' ;;
        pacman:geoiplookup) printf 'geoip\n' ;;
        pacman:geoipupdate) printf 'geoipupdate\n' ;;
        *)
            return 1
            ;;
    esac
}

install_packages() {
    local manager=$1
    shift
    local -a packages=("$@")

    [[ ${#packages[@]} -gt 0 ]] || return 0

    case "$manager" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        zypper)
            zypper --non-interactive install "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        *)
            die "不支持的包管理器: $manager"
            ;;
    esac
}

ensure_commands_installed() {
    local -a commands=("$@")
    local -a missing_commands=()
    local -a packages=()
    local manager pkg command_name

    for command_name in "${commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing_commands+=("$command_name")
        fi
    done

    [[ ${#missing_commands[@]} -eq 0 ]] && return 0

    manager="$(detect_package_manager)" || die "检测到缺少依赖: ${missing_commands[*]}，且未找到支持的包管理器。"

    for command_name in "${missing_commands[@]}"; do
        pkg="$(command_to_package_name "$manager" "$command_name" || true)"
        if [[ -z "$pkg" ]]; then
            die "缺少命令 $command_name，但当前包管理器 $manager 没有配置对应安装包名。"
        fi
        packages+=("$pkg")
    done

    log "检测到缺少依赖: ${missing_commands[*]}"
    log "将通过 $manager 安装: ${packages[*]}"
    install_packages "$manager" "${packages[@]}"
}

install_geoip_support() {
    local manager

    manager="$(detect_package_manager)" || {
        warn "未找到支持的包管理器，跳过 GeoIP 自动安装。"
        return 1
    }

    case "$manager" in
        apt-get)
            install_packages "$manager" geoip-bin geoip-database jq
            ;;
        dnf|yum)
            install_packages "$manager" GeoIP jq
            ;;
        zypper)
            install_packages "$manager" GeoIP jq
            ;;
        pacman)
            install_packages "$manager" geoip jq
            ;;
        *)
            warn "当前包管理器 $manager 未配置 GeoIP 自动安装。"
            return 1
            ;;
    esac

    return 0
}

ensure_geoip_ready() {
    if detect_geoip_db_path >/dev/null 2>&1; then
        GEOIP_ENABLED="true"
        GEOIP_DB_PATH="$(detect_geoip_db_path)"
        return 0
    fi

    if install_geoip_support && detect_geoip_db_path >/dev/null 2>&1; then
        GEOIP_ENABLED="true"
        GEOIP_DB_PATH="$(detect_geoip_db_path)"
        return 0
    fi

    GEOIP_ENABLED="false"
    GEOIP_DB_PATH=""
    return 1
}

is_non_public_ip() {
    local ip=${1:-}

    [[ -z "$ip" ]] && return 0

    case "$ip" in
        10.*|127.*|192.168.*|169.254.*|0.*)
            return 0
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            return 0
            ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
            return 0
            ;;
        ::1|::|fe80:*|FE80:*|fc*|FC*|fd*|FD*)
            return 0
            ;;
    esac

    return 1
}

ip_in_cidr_csv() {
    local ip=$1
    local cidrs=${2:-}

    [[ -z "$cidrs" ]] && return 1
    require_cmd "$PYTHON_BIN"

    "$PYTHON_BIN" - "$ip" "$cidrs" <<'PY'
import ipaddress
import sys

ip_text = sys.argv[1]
cidr_text = sys.argv[2]

try:
    ip_obj = ipaddress.ip_address(ip_text)
except ValueError:
    sys.exit(1)

for raw in cidr_text.split(","):
    raw = raw.strip()
    if not raw:
        continue
    try:
        if ip_obj in ipaddress.ip_network(raw, strict=False):
            sys.exit(0)
    except ValueError:
        continue

sys.exit(1)
PY
}

geoip_cache_file() {
    printf '%s/geoip-cache.tsv\n' "$CACHE_DIR"
}

detect_geoip_db_path() {
    local candidate

    if [[ -n "$GEOIP_DB_PATH" && -f "$GEOIP_DB_PATH" ]]; then
        printf '%s\n' "$GEOIP_DB_PATH"
        return 0
    fi

    for candidate in \
        /usr/share/GeoIP/GeoLite2-Country.mmdb \
        /usr/share/GeoIP/GeoLite2-City.mmdb \
        /usr/local/share/GeoIP/GeoLite2-Country.mmdb \
        /var/lib/GeoIP/GeoLite2-Country.mmdb \
        /usr/share/GeoIP/GeoIP.dat \
        /usr/local/share/GeoIP/GeoIP.dat
    do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

detect_geoip_provider() {
    local db_path
    db_path="$(detect_geoip_db_path 2>/dev/null || true)"

    if [[ "$GEOIP_ENABLED" == "false" ]]; then
        printf 'none\n'
        return 0
    fi

    if command -v "$MMDBLOOKUP_BIN" >/dev/null 2>&1 && [[ "$db_path" == *.mmdb ]]; then
        printf 'mmdb\n'
        return 0
    fi

    if command -v "$GEOIPLOOKUP_BIN" >/dev/null 2>&1 && [[ "$db_path" == *.dat ]]; then
        printf 'legacy\n'
        return 0
    fi

    printf 'none\n'
}

geoip_status_text() {
    local provider db_path
    provider="$(detect_geoip_provider)"
    db_path="$(detect_geoip_db_path 2>/dev/null || true)"

    case "$provider" in
        mmdb)
            printf '可用 (mmdb: %s)\n' "$db_path"
            ;;
        legacy)
            printf '可用 (legacy: %s)\n' "$db_path"
            ;;
        *)
            printf '不可用\n'
            ;;
    esac
}

lookup_country_info() {
    local ip=$1
    local cache_file provider db_path cached cache_line cached_code cached_name country_code country_name

    ensure_dirs
    cache_file="$(geoip_cache_file)"
    touch "$cache_file"

    if is_non_public_ip "$ip"; then
        printf 'PRIVATE\tPrivate\n'
        return 0
    fi

    provider="$(detect_geoip_provider)"
    db_path="$(detect_geoip_db_path 2>/dev/null || true)"

    cache_line="$(awk -F'\t' -v ip="$ip" '$1 == ip { print $2 "\t" $3; exit }' "$cache_file")"
    if [[ -n "$cache_line" ]]; then
        IFS=$'\t' read -r cached_code cached_name <<<"$cache_line"
        if [[ "$cached_code" != "UNKNOWN" || "$provider" == "none" ]]; then
            printf '%s\n' "$cache_line"
            return 0
        fi
    fi

    country_code="UNKNOWN"
    country_name="Unknown"

    case "$provider" in
        mmdb)
            cached="$("$MMDBLOOKUP_BIN" --file "$db_path" --ip "$ip" country iso_code 2>/dev/null | sed -n 's/.*"\\([^"]*\\)".*/\\1/p' | head -n 1)"
            if [[ -n "$cached" ]]; then
                country_code="$cached"
            else
                cached="$("$MMDBLOOKUP_BIN" --file "$db_path" --ip "$ip" registered_country iso_code 2>/dev/null | sed -n 's/.*"\\([^"]*\\)".*/\\1/p' | head -n 1)"
                [[ -n "$cached" ]] && country_code="$cached"
            fi

            cached="$("$MMDBLOOKUP_BIN" --file "$db_path" --ip "$ip" country names en 2>/dev/null | sed -n 's/.*"\\([^"]*\\)".*/\\1/p' | head -n 1)"
            if [[ -n "$cached" ]]; then
                country_name="$cached"
            elif [[ "$country_code" != "UNKNOWN" ]]; then
                country_name="$country_code"
            fi
            ;;
        legacy)
            cached="$("$GEOIPLOOKUP_BIN" "$ip" 2>/dev/null | sed 's/^.*: *//')"
            if [[ -n "$cached" && "$cached" != "IP Address not found" ]]; then
                country_code="$(printf '%s' "$cached" | awk -F',' '{print $1}' | tr -d ' ')"
                country_name="$(printf '%s' "$cached" | awk -F', ' '{print $2}')"
                [[ -z "$country_name" ]] && country_name="$country_code"
            fi
            ;;
    esac

    awk -F'\t' -v ip="$ip" '$1 != ip { print }' "$cache_file" > "$cache_file.tmp"
    mv "$cache_file.tmp" "$cache_file"
    printf '%s\t%s\t%s\n' "$ip" "$country_code" "$country_name" >> "$cache_file"
    printf '%s\t%s\n' "$country_code" "$country_name"
}

write_config_file() {
    local target_file=$1

    mkdir -p "$(dirname "$target_file")"

    cat > "$target_file" <<EOF
#!/usr/bin/env bash

DATA_DIR="${DATA_DIR}"
INSTALL_DIR="${INSTALL_DIR}"
BIN_LINK_PATH="${BIN_LINK_PATH}"
SYSTEM_CONFIG_DIR="${SYSTEM_CONFIG_DIR}"
SYSTEM_CONFIG_FILE="${SYSTEM_CONFIG_FILE}"
CAPTURE_INTERVAL_MINUTES="${CAPTURE_INTERVAL_MINUTES}"
CAPTURE_DIRECTION="${CAPTURE_DIRECTION}"
RETENTION_DAYS="${RETENTION_DAYS}"
EXCLUDE_SRC_CIDRS="${EXCLUDE_SRC_CIDRS}"
EXCLUDE_DST_CIDRS="${EXCLUDE_DST_CIDRS}"
INCLUDE_COUNTRY_CODES="${INCLUDE_COUNTRY_CODES}"
INCLUDE_LINK_LOCAL_IPV6="${INCLUDE_LINK_LOCAL_IPV6}"
INCUS_PROJECT="${INCUS_PROJECT}"
GEOIP_ENABLED="${GEOIP_ENABLED}"
GEOIP_DB_PATH="${GEOIP_DB_PATH}"
DEFAULT_REPORT_DAYS="${DEFAULT_REPORT_DAYS}"
DEFAULT_REPORT_LIMIT="${DEFAULT_REPORT_LIMIT}"
EOF
}

write_default_config() {
    write_config_file "$LOCAL_CONFIG_FILE"
}

service_unit_installed() {
    [[ -f "$SERVICE_UNIT_PATH" && -f "$TIMER_UNIT_PATH" ]]
}

systemctl_quiet() {
    "$SYSTEMCTL_BIN" "$@" >/dev/null 2>&1
}

print_tsv_table() {
    local file=$1

    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$file"
    else
        cat "$file"
    fi
}
