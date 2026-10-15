#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/mihomo-oneclick.py"
SERVICE_NAME="mihomo-oneclick.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
BIN_PATH="/usr/local/bin/mihomo"
CONFIG_PATH="/etc/mihomo-oneclick/config.yaml"
CONFIG_DIR="/etc/mihomo-oneclick"
STATE_DIR="/var/lib/mihomo-oneclick"
MARKER="$STATE_DIR/.managed-by-mihomo-oneclick"
KERNEL_DIR="$SCRIPT_DIR/kernels"
KERNEL_VERSION_FILE="$KERNEL_DIR/VERSION"
APPLY_STARTED=0
COMMITTED=0
MODE="install"

say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; exit 1; }

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    CALLER_USER="$SUDO_USER"
    CALLER_HOME="$(getent passwd "$CALLER_USER" | cut -d: -f6)"
    CALLER_GROUP="$(id -gn "$CALLER_USER")"
else
    CALLER_USER="${USER:-root}"
    CALLER_HOME="${HOME:-/root}"
    CALLER_GROUP="$(id -gn "$CALLER_USER" 2>/dev/null || printf '%s' root)"
fi
[[ -n "$CALLER_HOME" ]] || fail "无法定位运行用户的主目录。"
USER_CONFIG_DIR="${MIHOMO_ONECLICK_CONFIG_DIR:-$CALLER_HOME/.config/mihomo-oneclick}"
SUBSCRIPTION_FILE="$USER_CONFIG_DIR/subscription_url.txt"

[[ ! -L "$USER_CONFIG_DIR" ]] || fail "订阅配置目录不能是符号链接。"
[[ ! -L "$SUBSCRIPTION_FILE" ]] || fail "订阅配置文件不能是符号链接。"
if [[ ! -e "$SUBSCRIPTION_FILE" ]]; then
    if (( EUID == 0 )) && [[ "$CALLER_USER" != "root" ]]; then
        if [[ ! -d "$CALLER_HOME/.config" ]]; then
            install -d -m 755 -o "$CALLER_USER" -g "$CALLER_GROUP" "$CALLER_HOME/.config"
        fi
        if [[ "$USER_CONFIG_DIR" == "$CALLER_HOME/.config/mihomo-oneclick" ]]; then
            install -d -m 700 -o "$CALLER_USER" -g "$CALLER_GROUP" "$USER_CONFIG_DIR"
        else
            mkdir -p -- "$USER_CONFIG_DIR"
            chown "$CALLER_USER:$CALLER_GROUP" "$USER_CONFIG_DIR"
        fi
    else
        mkdir -p -- "$USER_CONFIG_DIR"
    fi
    install -m 600 "$SCRIPT_DIR/subscription_url.example" "$SUBSCRIPTION_FILE"
    if (( EUID == 0 )) && [[ "$CALLER_USER" != "root" ]]; then
        chown "$CALLER_USER:$CALLER_GROUP" "$USER_CONFIG_DIR" "$SUBSCRIPTION_FILE"
    fi
    say "已在工作区外创建订阅配置文件：$SUBSCRIPTION_FILE"
    say "请只在这个文件中写入一条 HTTPS 订阅地址，然后重新运行安装程序。"
    exit 0
fi
[[ ! -L "$SUBSCRIPTION_FILE" ]] || fail "订阅配置文件不能是符号链接。"

if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || fail "需要 root 权限；请安装 sudo 后重试。"
    exec sudo env MIHOMO_ONECLICK_CONFIG_DIR="$USER_CONFIG_DIR" "$SCRIPT_DIR/install.sh" "$@"
fi

[[ -f "$HELPER" ]] || fail "缺少内部配置工具文件。"
command -v python3 >/dev/null 2>&1 || fail "缺少 Python 3。"
command -v sha256sum >/dev/null 2>&1 || fail "缺少 sha256sum。"
command -v gzip >/dev/null 2>&1 || fail "缺少 gzip。"
command -v systemctl >/dev/null 2>&1 || fail "当前系统未提供 systemd。"
[[ -d /run/systemd/system ]] || fail "systemd 当前未运行；此部署程序面向使用 systemd 的 Linux。"

if [[ -f "$MARKER" ]]; then
    MODE="update"
    [[ -f "$BIN_PATH" && -f "$CONFIG_PATH" && -f "$SERVICE_PATH" ]] || fail "已有部署标记，但 Mihomo 文件不完整；请先手动检查后再操作。"
else
    for target in "$BIN_PATH" "$CONFIG_DIR" "$SERVICE_PATH" "$STATE_DIR"; do
        [[ ! -e "$target" ]] || fail "目标路径已存在且不属于本程序：$target"
    done
fi

chmod 600 "$SUBSCRIPTION_FILE"
python3 "$HELPER" validate-subscription "$SUBSCRIPTION_FILE" || fail "订阅配置无效。"

case "$(uname -m)" in
    x86_64|amd64) MIHOMO_ASSET="mihomo-linux-amd64-compatible"; YQ_ARCH="amd64" ;;
    aarch64|arm64) MIHOMO_ASSET="mihomo-linux-arm64"; YQ_ARCH="arm64" ;;
    armv7l|armv7*) MIHOMO_ASSET="mihomo-linux-armv7"; YQ_ARCH="arm" ;;
    i386|i686) MIHOMO_ASSET="mihomo-linux-386"; YQ_ARCH="386" ;;
    *) fail "不支持的 CPU 架构：$(uname -m)" ;;
esac
[[ -f "$KERNEL_VERSION_FILE" && -f "$KERNEL_DIR/SHA256SUMS" ]] || fail "仓库中缺少 Mihomo 内核文件或校验清单。"
KERNEL_VERSION="$(tr -d '\r\n' < "$KERNEL_VERSION_FILE")"
[[ "$KERNEL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "仓库内 Mihomo 版本号格式无效。"
KERNEL_FILE="$MIHOMO_ASSET-$KERNEL_VERSION.gz"
BUNDLED_KERNEL="$KERNEL_DIR/$KERNEL_FILE"
[[ -f "$BUNDLED_KERNEL" ]] || fail "仓库中没有适配当前架构的 Mihomo 内核：$KERNEL_FILE"
KERNEL_SHA="$(awk -v name="$KERNEL_FILE" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$KERNEL_DIR/SHA256SUMS")" || fail "SHA-256 清单中没有唯一的当前架构内核记录。"
[[ "$KERNEL_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || fail "内核 SHA-256 清单格式无效。"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-oneclick.XXXXXXXX")"
chmod 700 "$TMP_DIR"
PROFILE="$TMP_DIR/subscription.yaml"
PROFILE_JSON="$TMP_DIR/profile.json"
CANDIDATE="$TMP_DIR/config.yaml"
MIHOMO_BIN="$TMP_DIR/mihomo"
YQ_BIN="$TMP_DIR/yq"
YQ_META="$TMP_DIR/yq-release.json"
RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -m 700 "$RUNTIME_DIR"

cleanup() {
    local status=$?
    if (( APPLY_STARTED == 1 && COMMITTED == 0 )); then
        say "部署没有完成，正在回滚本程序刚写入的文件……" >&2
        if [[ "$MODE" == "update" ]]; then
            install -m 755 "$TMP_DIR/old-mihomo" "$BIN_PATH" 2>/dev/null || true
            install -m 600 "$TMP_DIR/old-config.yaml" "$CONFIG_PATH" 2>/dev/null || true
            install -m 644 "$TMP_DIR/old-service" "$SERVICE_PATH" 2>/dev/null || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
        else
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f -- "$SERVICE_PATH" "$BIN_PATH"
            rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
    [[ -z "${TMP_DIR:-}" ]] || rm -rf -- "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT

fetch_release_asset() {
    local repository="$1" platform="$2" metadata="$3"
    local url digest
    if ! python3 "$HELPER" download "https://api.github.com/repos/$repository/releases/latest" \
        "$metadata" 10485760 github >/dev/null 2>&1; then
        fail "无法读取官方发布信息（$repository）。"
    fi
    local asset_info
    asset_info="$(python3 "$HELPER" release-asset "$metadata" "$repository" "$platform")" || fail "官方发布包选择失败。"
    IFS=$'\t' read -r url digest <<< "$asset_info"
    [[ "$url" == https://github.com/*/releases/download/* ]] || fail "官方下载地址异常。"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || fail "官方 SHA-256 信息异常。"
    printf '%s\t%s\n' "$url" "$digest"
}

verify_download() {
    local path="$1" expected="$2"
    printf '%s  %s\n' "$expected" "$path" | sha256sum --check --status - || fail "下载包 SHA-256 校验失败。"
}

say "正在校验仓库内的 Mihomo $KERNEL_VERSION（$KERNEL_FILE）……"
printf '%s  %s\n' "$KERNEL_SHA" "$BUNDLED_KERNEL" | sha256sum --check --status - || fail "仓库内 Mihomo 内核 SHA-256 校验失败。"
gzip -t "$BUNDLED_KERNEL" >/dev/null 2>&1 || fail "仓库内 Mihomo 内核压缩包无效。"
gzip -dc "$BUNDLED_KERNEL" > "$MIHOMO_BIN" || fail "无法解压仓库内 Mihomo 内核。"
chmod 700 "$MIHOMO_BIN"

say "正在从官方发布源准备 YAML 解析工具……"
YQ_ASSET_INFO="$(fetch_release_asset "mikefarah/yq" "$YQ_ARCH" "$YQ_META")" || fail "YAML 解析工具准备失败。"
IFS=$'\t' read -r YQ_URL YQ_SHA <<< "$YQ_ASSET_INFO"
if ! python3 "$HELPER" download "$YQ_URL" "$YQ_BIN" 104857600 binary >/dev/null 2>&1; then
    fail "YAML 解析工具下载失败。"
fi
verify_download "$YQ_BIN" "$YQ_SHA"
chmod 700 "$YQ_BIN"

say "正在获取订阅配置并读取节点列表……"
if ! python3 "$HELPER" download-subscription "$SUBSCRIPTION_FILE" "$PROFILE" 52428800 >/dev/null 2>&1; then
    fail "订阅配置下载失败；请检查订阅地址或网络。"
fi
[[ -s "$PROFILE" ]] || fail "订阅返回了空文件。"
if ! "$YQ_BIN" eval -o=json '.' "$PROFILE" > "$PROFILE_JSON" 2>/dev/null; then
    fail "订阅内容不是可读取的 Mihomo/Clash YAML 配置。"
fi
if ! python3 "$HELPER" list-nodes "$PROFILE_JSON" > "$TMP_DIR/nodes.txt"; then
    fail "无法从订阅配置提取节点。"
fi

say "\n订阅中的节点："
while IFS=$'\t' read -r node_index node_name; do
    printf '  %s) %s\n' "$node_index" "$node_name"
done < "$TMP_DIR/nodes.txt"

NODE_COUNT="$(wc -l < "$TMP_DIR/nodes.txt" | tr -d '[:space:]')"
[[ "$NODE_COUNT" =~ ^[0-9]+$ && "$NODE_COUNT" -gt 0 ]] || fail "订阅中没有可用节点。"
while true; do
    read -r -p "请输入要使用的节点序号：" NODE_INDEX
    if [[ "$NODE_INDEX" =~ ^[0-9]+$ ]] && (( NODE_INDEX >= 1 && NODE_INDEX <= NODE_COUNT )); then
        break
    fi
    say "序号无效，请输入列表中的数字。"
done

if ! python3 "$HELPER" configure "$PROFILE_JSON" "$NODE_INDEX" > "$CANDIDATE"; then
    fail "无法生成规则模式配置。"
fi
if ! "$MIHOMO_BIN" -d "$RUNTIME_DIR" -t -f "$CANDIDATE" >/dev/null 2>&1; then
    fail "Mihomo 配置检查未通过；尚未修改系统。"
fi

if [[ "$MODE" == "update" ]]; then
    cp -p -- "$BIN_PATH" "$TMP_DIR/old-mihomo"
    cp -p -- "$CONFIG_PATH" "$TMP_DIR/old-config.yaml"
    cp -p -- "$SERVICE_PATH" "$TMP_DIR/old-service"
    say "\n检测到本程序此前部署的 Mihomo，将更新内核和配置并重启本程序的服务。"
else
    say "\n即将安装 Mihomo，并启用本机 TUN 规则代理。"
fi
say "将写入：$BIN_PATH、$CONFIG_PATH、$SERVICE_PATH、$STATE_DIR"
say "启用后会调整本机路由与 DNS；回滚方式见同目录 README.md。"
read -r -p "确认继续请输入 INSTALL：" CONFIRM
[[ "$CONFIRM" == "INSTALL" ]] || fail "用户取消，尚未修改系统。"

APPLY_STARTED=1
if [[ "$MODE" == "install" ]]; then
    install -d -m 700 "$CONFIG_DIR" "$STATE_DIR"
    printf '%s\n' 'mihomo-oneclick' > "$MARKER"
    chmod 600 "$MARKER"
fi
install -m 755 "$MIHOMO_BIN" "$BIN_PATH"
install -m 600 "$CANDIDATE" "$CONFIG_PATH"
cat > "$TMP_DIR/service" <<'UNIT'
[Unit]
Description=Mihomo local rule-based proxy (one-click deployment)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/mihomo-oneclick
ExecStart=/usr/local/bin/mihomo -d /var/lib/mihomo-oneclick -f /etc/mihomo-oneclick/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=/var/lib/mihomo-oneclick

[Install]
WantedBy=multi-user.target
UNIT
install -m 644 "$TMP_DIR/service" "$SERVICE_PATH"
systemctl daemon-reload
if [[ "$MODE" == "install" ]]; then
    systemctl enable --now "$SERVICE_NAME"
else
    systemctl restart "$SERVICE_NAME"
fi
COMMITTED=1

say "\n完成：Mihomo 已配置为 rule 模式，并已选择节点序号 $NODE_INDEX。"
say "订阅配置文件：$SUBSCRIPTION_FILE"
say "更换上游后编辑该文件，再重新运行本程序即可更新部署。"
