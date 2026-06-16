#!/usr/bin/env bash
set -euo pipefail

REPO="${INCUSCHECK_REPO:-piphase/incuscheck}"
REF="${INCUSCHECK_REF:-main}"
MODE="${1:-menu}"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: 缺少命令: %s\n' "$1" >&2
        exit 1
    }
}

download() {
    local url=$1
    local output=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
        return
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
        return
    fi

    printf 'ERROR: 需要 curl 或 wget 才能拉取安装包。\n' >&2
    exit 1
}

ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
ARCHIVE_FILE="$TMP_DIR/incuscheck.tar.gz"

require_cmd tar
download "$ARCHIVE_URL" "$ARCHIVE_FILE"
tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"

SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'incuscheck-*' | head -n 1)"
[[ -n "$SRC_DIR" ]] || {
    printf 'ERROR: 解压后的源码目录未找到。\n' >&2
    exit 1
}

chmod +x \
    "$SRC_DIR/incuscheck.sh" \
    "$SRC_DIR/checklist.sh" \
    "$SRC_DIR/conntrack-capture.sh" \
    "$SRC_DIR/conntrack-report.sh" \
    "$SRC_DIR/lib/common.sh"

case "$MODE" in
    install|reinstall)
        exec "$SRC_DIR/incuscheck.sh" --install-defaults
        ;;
    uninstall)
        exec "$SRC_DIR/incuscheck.sh" --uninstall-force
        ;;
    status)
        exec "$SRC_DIR/incuscheck.sh" --debug-status
        ;;
    run-once)
        exec "$SRC_DIR/incuscheck.sh" --run-once
        ;;
    menu|"")
        exec "$SRC_DIR/incuscheck.sh"
        ;;
    *)
        shift || true
        exec "$SRC_DIR/incuscheck.sh" "$MODE" "$@"
        ;;
esac
