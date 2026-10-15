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
YQ_DIR="$SCRIPT_DIR/tools/yq"
YQ_VERSION_FILE="$YQ_DIR/VERSION"
DATA_DIR="$SCRIPT_DIR/data"
GEODATA_FILES=(Country.mmdb GeoSite.dat)
INIT_STATE_DIR="/var/lib/mihomo-oneclick-bootstrap"
INIT_STATE_FILE="$INIT_STATE_DIR/initialized-v1"
APT_BACKUP_DIR="/var/backups/mihomo-oneclick/apt-sources"
APT_SOURCES_LIST="/etc/apt/sources.list"
APT_UBUNTU_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"
APPLY_STARTED=0
COMMITTED=0
APT_CHANGE_IN_PROGRESS=0
MODE="install"

say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; exit 1; }

read_os_release_value() {
    awk -F= -v key="$1" '$1 == key { value = $2; sub(/^"/, "", value); sub(/"$/, "", value); print value; exit }' /etc/os-release
}

write_init_state() {
    local status="$1" temporary
    [[ ! -L "$INIT_STATE_FILE" ]] || fail "初始化状态文件不能是符号链接。"
    if [[ -e "$INIT_STATE_DIR" ]]; then
        [[ -d "$INIT_STATE_DIR" && ! -L "$INIT_STATE_DIR" ]] || fail "初始化状态目录路径被占用：$INIT_STATE_DIR"
    else
        install -d -m 700 "$INIT_STATE_DIR"
    fi
    temporary="$(mktemp "$INIT_STATE_DIR/.state.XXXXXXXX")"
    printf 'count=1\nstatus=%s\n' "$status" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$INIT_STATE_FILE"
}

save_original_apt_sources() {
    local staged="$TMP_DIR/apt-sources-backup" backup_root="/var/backups/mihomo-oneclick"
    [[ ! -L "$backup_root" && ! -L "$APT_BACKUP_DIR" && ! -L /etc/apt/sources.list.d ]] || fail "APT 回滚目录或软件源目录不能是符号链接。"
    [[ ! -L "$APT_SOURCES_LIST" && ! -L "$APT_UBUNTU_SOURCES" ]] || fail "检测到符号链接形式的 Ubuntu 软件源文件；为避免覆盖其他文件，已停止。"
    if [[ -f "$APT_BACKUP_DIR/.saved" ]]; then
        return
    fi
    [[ ! -e "$APT_BACKUP_DIR" ]] || fail "APT 回滚目录已存在但备份标记缺失：$APT_BACKUP_DIR"
    if [[ -e "$backup_root" ]]; then
        [[ -d "$backup_root" ]] || fail "APT 回滚目录路径已被占用：$backup_root"
    else
        install -d -m 700 "$backup_root"
    fi
    install -d -m 700 "$staged"
    if [[ -e "$APT_SOURCES_LIST" ]]; then
        cp -a -- "$APT_SOURCES_LIST" "$staged/sources.list"
        : > "$staged/had-sources.list"
    fi
    if [[ -e "$APT_UBUNTU_SOURCES" ]]; then
        cp -a -- "$APT_UBUNTU_SOURCES" "$staged/ubuntu.sources"
        : > "$staged/had-ubuntu.sources"
    fi
    : > "$staged/.saved"
    chmod 600 "$staged/.saved" "$staged/had-sources.list" "$staged/had-ubuntu.sources" 2>/dev/null || true
    mv -- "$staged" "$APT_BACKUP_DIR"
    chmod 700 "$APT_BACKUP_DIR"
}

restore_apt_sources() {
    [[ -f "$APT_BACKUP_DIR/.saved" ]] || return 0
    [[ ! -L "$APT_SOURCES_LIST" && ! -L "$APT_UBUNTU_SOURCES" && ! -L /etc/apt/sources.list.d ]] || return 1
    if [[ -f "$APT_BACKUP_DIR/had-sources.list" ]]; then
        cp -a -- "$APT_BACKUP_DIR/sources.list" "$APT_SOURCES_LIST"
    else
        rm -f -- "$APT_SOURCES_LIST"
    fi
    if [[ -f "$APT_BACKUP_DIR/had-ubuntu.sources" ]]; then
        if [[ ! -d /etc/apt/sources.list.d ]]; then
            install -d -m 755 /etc/apt/sources.list.d
        fi
        cp -a -- "$APT_BACKUP_DIR/ubuntu.sources" "$APT_UBUNTU_SOURCES"
    else
        rm -f -- "$APT_UBUNTU_SOURCES"
    fi
}

initialize_ubuntu_apt_once() {
    local os_id os_codename status temporary
    os_id="$(read_os_release_value ID)"
    os_codename="$(read_os_release_value VERSION_CODENAME)"

    [[ ! -L "$INIT_STATE_DIR" && ! -L "$INIT_STATE_FILE" ]] || fail "初始化状态路径不能是符号链接。"
    if [[ -e "$INIT_STATE_FILE" && ! -f "$INIT_STATE_FILE" ]]; then
        fail "初始化状态文件格式无效。"
    fi
    if [[ -f "$INIT_STATE_FILE" ]]; then
        status="$(awk -F= '$1 == "status" { print $2; exit }' "$INIT_STATE_FILE")"
        [[ "$(awk -F= '$1 == "count" { print $2; exit }' "$INIT_STATE_FILE")" == 1 ]] || fail "初始化计数状态无效。"
        case "$status" in
            complete|skipped-existing-install)
                say "检测到首次初始化记录（count=1），跳过镜像源切换和 APT 更新。"
                return
                ;;
            *) fail "初始化状态内容无效。" ;;
        esac
    fi

    if [[ "$MODE" == "update" ]]; then
        say "检测到已有 Mihomo 部署，跳过仅首次部署执行的镜像源切换和 APT 更新。"
        write_init_state skipped-existing-install
        return
    fi

    if [[ "$os_id" != "ubuntu" ]]; then
        say "当前系统不是 Ubuntu，跳过 Ubuntu 专用镜像源初始化。"
        return
    fi
    [[ "$os_codename" =~ ^[a-z][a-z0-9.-]*$ ]] || fail "无法安全识别 Ubuntu 发行代号。"
    command -v apt >/dev/null 2>&1 || fail "Ubuntu 系统未提供 apt。"

    say "首次初始化：备份当前 Ubuntu 软件源到 $APT_BACKUP_DIR。"
    save_original_apt_sources
    APT_CHANGE_IN_PROGRESS=1

    say "正在将 Ubuntu $os_codename 软件源切换到阿里云镜像；安全更新仍使用 security.ubuntu.com。"
    if [[ -e /etc/apt/sources.list.d ]]; then
        [[ -d /etc/apt/sources.list.d && ! -L /etc/apt/sources.list.d ]] || fail "APT 软件源目录路径异常。"
    else
        install -d -m 755 /etc/apt/sources.list.d
    fi
    temporary="$(mktemp /etc/apt/.mihomo-sources.XXXXXXXX)"
    cat > "$temporary" <<EOF
deb https://mirrors.aliyun.com/ubuntu/ $os_codename main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $os_codename-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $os_codename-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $os_codename-security main restricted universe multiverse
EOF
    chmod 644 "$temporary"
    mv -f -- "$temporary" "$APT_SOURCES_LIST"
    rm -f -- "$APT_UBUNTU_SOURCES"

    say "正在清理 APT 缓存（apt clean）……"
    apt clean || fail "apt clean 失败；正在恢复原 Ubuntu 软件源。"
    say "正在更新软件包索引（apt update）……"
    apt update || fail "apt update 失败；正在恢复原 Ubuntu 软件源。"

    write_init_state complete
    APT_CHANGE_IN_PROGRESS=0
    say "Ubuntu 软件源初始化完成；后续运行将跳过该步骤。"
}

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
command -v tar >/dev/null 2>&1 || fail "缺少 tar。"
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
    x86_64|amd64) MIHOMO_ASSET="mihomo-linux-amd64-compatible"; YQ_ASSET="yq_linux_amd64" ;;
    aarch64|arm64) MIHOMO_ASSET="mihomo-linux-arm64"; YQ_ASSET="yq_linux_arm64" ;;
    armv7l|armv7*) MIHOMO_ASSET="mihomo-linux-armv7"; YQ_ASSET="yq_linux_arm" ;;
    i386|i686) MIHOMO_ASSET="mihomo-linux-386"; YQ_ASSET="yq_linux_386" ;;
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
[[ -f "$YQ_VERSION_FILE" && -f "$YQ_DIR/SHA256SUMS" ]] || fail "仓库中缺少 yq 工具文件或校验清单。"
YQ_VERSION="$(tr -d '\r\n' < "$YQ_VERSION_FILE")"
[[ "$YQ_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "仓库内 yq 版本号格式无效。"
YQ_FILE="$YQ_ASSET-$YQ_VERSION.tar.gz"
BUNDLED_YQ="$YQ_DIR/$YQ_FILE"
[[ -f "$BUNDLED_YQ" ]] || fail "仓库中没有适配当前架构的 yq 工具：$YQ_FILE"
YQ_SHA="$(awk -v name="$YQ_FILE" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$YQ_DIR/SHA256SUMS")" || fail "SHA-256 清单中没有唯一的当前架构 yq 记录。"
[[ "$YQ_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || fail "yq SHA-256 清单格式无效。"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-oneclick.XXXXXXXX")"
chmod 700 "$TMP_DIR"
PROFILE="$TMP_DIR/subscription.yaml"
PROFILE_NORMALIZED="$TMP_DIR/subscription.normalized.yaml"
PROFILE_JSON="$TMP_DIR/profile.json"
CANDIDATE="$TMP_DIR/config.yaml"
MIHOMO_BIN="$TMP_DIR/mihomo"
YQ_BIN="$TMP_DIR/yq"
RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -m 700 "$RUNTIME_DIR"

cleanup() {
    local status=$?
    if (( APT_CHANGE_IN_PROGRESS == 1 )); then
        if restore_apt_sources 2>/dev/null; then
            say "APT 初始化未完成，已恢复原 Ubuntu 软件源；apt clean 已清理的软件包缓存不会自动恢复。" >&2
        else
            say "APT 初始化未完成，自动恢复软件源失败；请从 $APT_BACKUP_DIR 手动恢复。" >&2
        fi
    fi
    if (( APPLY_STARTED == 1 && COMMITTED == 0 )); then
        say "部署没有完成，正在回滚本程序刚写入的文件……" >&2
        if [[ "$MODE" == "update" ]]; then
            install -m 755 "$TMP_DIR/old-mihomo" "$BIN_PATH" 2>/dev/null || true
            install -m 600 "$TMP_DIR/old-config.yaml" "$CONFIG_PATH" 2>/dev/null || true
            install -m 644 "$TMP_DIR/old-service" "$SERVICE_PATH" 2>/dev/null || true
            for asset in "${GEODATA_FILES[@]}"; do
                if [[ -f "$TMP_DIR/old-geodata/$asset" ]]; then
                    install -m 600 "$TMP_DIR/old-geodata/$asset" "$STATE_DIR/$asset" 2>/dev/null || true
                else
                    rm -f -- "$STATE_DIR/$asset"
                fi
            done
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

verify_sha256() {
    local path="$1" expected="$2"
    printf '%s  %s\n' "$expected" "$path" | sha256sum --check --status - || fail "SHA-256 校验失败：$path"
}

say "正在校验仓库内的 Mihomo $KERNEL_VERSION（$KERNEL_FILE）……"
printf '%s  %s\n' "$KERNEL_SHA" "$BUNDLED_KERNEL" | sha256sum --check --status - || fail "仓库内 Mihomo 内核 SHA-256 校验失败。"
gzip -t "$BUNDLED_KERNEL" >/dev/null 2>&1 || fail "仓库内 Mihomo 内核压缩包无效。"
gzip -dc "$BUNDLED_KERNEL" > "$MIHOMO_BIN" || fail "无法解压仓库内 Mihomo 内核。"
chmod 700 "$MIHOMO_BIN"

say "正在校验仓库内的 YAML 解析工具 $YQ_VERSION（$YQ_FILE）……"
verify_sha256 "$BUNDLED_YQ" "$YQ_SHA"
tar -tzf "$BUNDLED_YQ" | awk -v expected="./$YQ_ASSET" '$0 == expected { found = 1 } END { exit !found }' || fail "仓库内 yq 压缩包缺少对应架构的程序。"
tar -xzf "$BUNDLED_YQ" -C "$TMP_DIR" "./$YQ_ASSET" || fail "无法解压仓库内 yq。"
mv -- "$TMP_DIR/$YQ_ASSET" "$YQ_BIN"
chmod 700 "$YQ_BIN"
YQ_ACTUAL_VERSION="$("$YQ_BIN" --version 2>/dev/null)" || fail "仓库内 yq 无法运行。"
[[ "$YQ_ACTUAL_VERSION" == *"$YQ_VERSION"* ]] || fail "仓库内 yq 版本与版本记录不一致。"
say "仓库内 yq 已就绪，不会从远端下载。"

say "正在校验并加载仓库内的 GeoIP/GeoSite 地区库……"
[[ -f "$DATA_DIR/SHA256SUMS" ]] || fail "仓库中缺少地区库 SHA-256 清单。"
for asset in "${GEODATA_FILES[@]}"; do
    [[ -f "$DATA_DIR/$asset" ]] || fail "仓库中缺少地区库：$asset"
    asset_sha="$(awk -v name="$asset" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$DATA_DIR/SHA256SUMS")" || fail "地区库校验清单缺少唯一记录：$asset"
    [[ "$asset_sha" =~ ^[0-9a-fA-F]{64}$ ]] || fail "地区库 SHA-256 清单格式无效：$asset"
    verify_sha256 "$DATA_DIR/$asset" "$asset_sha"
    install -m 600 "$DATA_DIR/$asset" "$RUNTIME_DIR/$asset"
done
say "本地 GeoIP/GeoSite 地区库已就绪。"

initialize_ubuntu_apt_once

say "正在获取订阅配置并读取节点列表……"
if ! python3 "$HELPER" download-subscription "$SUBSCRIPTION_FILE" "$PROFILE" 52428800; then
    fail "订阅配置下载失败；请检查订阅地址或网络。"
fi
[[ -s "$PROFILE" ]] || fail "订阅返回了空文件。"
say "正在识别订阅编码……"
python3 "$HELPER" normalize-subscription "$PROFILE" "$PROFILE_NORMALIZED"
say "正在解析订阅 YAML……"
if ! "$YQ_BIN" eval -o=json '.' "$PROFILE_NORMALIZED" > "$PROFILE_JSON" 2>/dev/null; then
    fail "订阅响应无法解析为 YAML；可能是网页错误页、协议节点列表或非 Mihomo/Clash 格式。为保护订阅信息，未输出响应内容。"
fi
python3 "$HELPER" list-nodes "$PROFILE_JSON" > "$TMP_DIR/nodes.txt"

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
say "正在使用本地地区库检查 Mihomo 配置……"
if ! python3 "$HELPER" check-config "$MIHOMO_BIN" "$RUNTIME_DIR" "$CANDIDATE"; then
    fail "Mihomo 配置检查未通过；请查看上方的内核错误。"
fi

if [[ "$MODE" == "update" ]]; then
    cp -p -- "$BIN_PATH" "$TMP_DIR/old-mihomo"
    cp -p -- "$CONFIG_PATH" "$TMP_DIR/old-config.yaml"
    cp -p -- "$SERVICE_PATH" "$TMP_DIR/old-service"
    mkdir -m 700 "$TMP_DIR/old-geodata"
    for asset in "${GEODATA_FILES[@]}"; do
        if [[ -f "$STATE_DIR/$asset" ]]; then
            cp -p -- "$STATE_DIR/$asset" "$TMP_DIR/old-geodata/$asset"
        fi
    done
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
for asset in "${GEODATA_FILES[@]}"; do
    install -m 600 "$RUNTIME_DIR/$asset" "$STATE_DIR/$asset"
done
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
