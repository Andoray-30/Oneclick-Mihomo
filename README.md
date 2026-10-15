# Mihomo 一键部署

在使用 systemd 的 Linux 主机上安装 Mihomo，以规则模式代理本机流量。Mihomo 内核和 `yq` 配置解析工具均已随仓库提供，安装时不会单独下载它们。

## 使用

1. 克隆仓库并进入目录：

   ```bash
   git clone https://github.com/Andoray-30/Oneclick-Mihomo.git
   cd Oneclick-Mihomo
   ```

2. 首次运行安装器，按提示在工作区外创建订阅地址文件：

   ```bash
   sudo ./install.sh
   ```

   在 `~/.config/mihomo-oneclick/subscription_url.txt` 中写入一条 HTTPS 订阅地址。

3. 再次运行 `sudo ./install.sh`，选择终端列出的节点。检查通过后输入 `INSTALL` 完成部署。

订阅必须返回 Mihomo/Clash YAML，且包含顶层 `proxies:` 节点列表。Base64 包装的 YAML 会自动解码；只返回 `ss://` 等节点链接、网页错误页或仅含 `proxy-providers` 的订阅暂不支持。安装器使用 Clash Verge Rev 默认请求标识，并只记录 HTTP 状态、响应类型等诊断信息；若返回 `text/html`，请检查桌面端自定义请求标识、代理更新设置和服务端访问限制。不会记录订阅地址或正文。

再次运行安装器会重新拉取订阅，供更换上游或节点；已部署后的运行不会重复初始化 APT 镜像源。

## Ubuntu 镜像源初始化

首次部署时，Ubuntu 会先备份软件源，再将发行版对应的软件源切换到阿里云，安全更新仍使用 `security.ubuntu.com`，随后执行 `apt clean` 和 `apt update`。`apt clean` 会清除本地已下载的软件包缓存；恢复源文件时不会恢复这些缓存。初始化完成后会记录 `count=1`，后续运行跳过这些步骤。其他 Linux 发行版不会修改软件源。

原软件源备份位于 `/var/backups/mihomo-oneclick/apt-sources/`。要恢复，运行：

```bash
sudo ./restore-ubuntu-sources.sh
sudo apt update
```

恢复脚本会要求输入 `RESTORE`。卸载 Mihomo 不会自动改回系统软件源。

## 更换订阅和卸载

更换订阅时编辑 `~/.config/mihomo-oneclick/subscription_url.txt`，再运行安装器选择节点并确认 `INSTALL`。真实订阅地址不应提交到仓库。

卸载运行 `sudo ./uninstall.sh`，输入 `REMOVE`。这会移除本程序的服务、内核、配置和运行数据，但保留外部订阅地址及 Ubuntu 软件源初始化记录。

## 系统要求

- 使用 systemd 的 Linux；支持 x86_64、ARM64、ARMv7 和 32 位 x86。
- Python 3、gzip、tar、sha256sum，以及 root 或 sudo 权限。
- 需要访问订阅地址；首次获取仓库仍需能访问 GitHub。

Mihomo `v1.19.32` 位于 `kernels/`，`yq v4.54.1` 位于 `tools/yq/`，均带 SHA-256 清单和许可证。启用 TUN 会调整本机路由与 DNS；配置检查通过且用户输入 `INSTALL` 后才会部署。
