#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="/var/backups/mihomo-oneclick/apt-sources"
INIT_STATE_FILE="/var/lib/mihomo-oneclick-bootstrap/initialized-v1"
SOURCES_LIST="/etc/apt/sources.list"
UBUNTU_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || fail "需要 root 权限；请安装 sudo 后重试。"
    exec sudo "$0" "$@"
fi

[[ ! -L "$BACKUP_DIR" && -f "$BACKUP_DIR/.saved" ]] || fail "找不到安全的原 Ubuntu 软件源备份：$BACKUP_DIR"
[[ ! -L "$SOURCES_LIST" && ! -L "$UBUNTU_SOURCES" && ! -L /etc/apt/sources.list.d ]] || fail "检测到符号链接形式的软件源路径；为避免覆盖其他文件，已停止。"

printf '%s\n' "即将恢复安装前的软件源配置。备份：$BACKUP_DIR"
read -r -p "确认恢复请输入 RESTORE：" CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || fail "用户取消。"

if [[ -f "$BACKUP_DIR/had-sources.list" ]]; then
    cp -a -- "$BACKUP_DIR/sources.list" "$SOURCES_LIST"
else
    rm -f -- "$SOURCES_LIST"
fi

if [[ -f "$BACKUP_DIR/had-ubuntu.sources" ]]; then
    install -d -m 755 /etc/apt/sources.list.d
    cp -a -- "$BACKUP_DIR/ubuntu.sources" "$UBUNTU_SOURCES"
else
    rm -f -- "$UBUNTU_SOURCES"
fi

rm -f -- "$INIT_STATE_FILE"
rm -rf -- "$BACKUP_DIR"
rmdir --ignore-fail-on-non-empty /var/backups/mihomo-oneclick 2>/dev/null || true

printf '%s\n' "已恢复软件源文件。运行 sudo apt update 刷新软件包索引。"
