#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="mihomo-oneclick.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
BIN_PATH="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo-oneclick"
STATE_DIR="/var/lib/mihomo-oneclick"
MARKER="$STATE_DIR/.managed-by-mihomo-oneclick"

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || fail "需要 root 权限；请安装 sudo 后重试。"
    exec sudo "$0" "$@"
fi
command -v systemctl >/dev/null 2>&1 || fail "当前系统未提供 systemd。"
[[ -f "$MARKER" ]] || fail "找不到本程序的部署标记；为避免误删文件，已停止。"

printf '%s\n' "将停止并移除 $SERVICE_NAME、$BIN_PATH、$CONFIG_DIR 和 $STATE_DIR。"
printf '%s\n' "外部订阅地址文件不会删除。"
printf '%s\n' "Ubuntu 软件源设置会保留；如需恢复，请运行 sudo ./restore-ubuntu-sources.sh。"
read -r -p "确认移除请输入 REMOVE：" CONFIRM
[[ "$CONFIRM" == "REMOVE" ]] || fail "用户取消。"

systemctl disable --now "$SERVICE_NAME"
systemctl daemon-reload
rm -f -- "$SERVICE_PATH" "$BIN_PATH"
rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
printf '%s\n' "已移除 Mihomo 一键部署文件和运行数据。"
