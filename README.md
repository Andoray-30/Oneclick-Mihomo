# Mihomo 一键部署

在使用 systemd 的 Linux 主机上安装 Mihomo，用所选节点代理本机流量。代理规则取自订阅配置。Mihomo 内核已随仓库提供，安装时不会下载内核。

## 使用

1. 克隆仓库并进入目录：

   ```bash
   git clone https://github.com/Andoray-30/Oneclick-Mihomo.git
   cd Oneclick-Mihomo
   ```

2. 首次运行安装器：

   ```bash
   sudo ./install.sh
   ```

   安装器会创建订阅地址文件：`~/.config/mihomo-oneclick/subscription_url.txt`。在文件中写入一条 HTTPS 格式的 Mihomo/Clash YAML 订阅地址。

3. 再次运行 `sudo ./install.sh`，从终端显示的节点列表中输入编号。检查通过后，输入 `INSTALL` 确认部署。

部署完成后，Mihomo 以 `rule` 模式运行，并通过 TUN 自动接管本机流量。每个域名是直连还是代理，由订阅里的规则决定。

## 更换订阅

编辑 `~/.config/mihomo-oneclick/subscription_url.txt`，替换为新的 HTTPS 地址，然后再次运行 `sudo ./install.sh`，选择节点并输入 `INSTALL`。安装器会更新订阅配置，并继续使用仓库内置的内核版本。

真实订阅地址保存在工作区外，避免把令牌提交到仓库。部署后的配置位于 `/etc/mihomo-oneclick/config.yaml`。

## 卸载

运行：

```bash
sudo ./uninstall.sh
```

输入 `REMOVE` 后，安装器会停止并移除本程序的服务、内核、配置和运行数据。外部订阅地址文件会保留。

## 系统要求

- 使用 systemd 的 Linux；支持 x86_64、ARM64、ARMv7 和 32 位 x86。
- Python 3、gzip、sha256sum，以及 root 或 sudo 权限。
- 可以访问 GitHub（获取 YAML 解析工具）和订阅地址。

仓库内置 Mihomo `v1.19.32` 的 x86_64、ARM64、ARMv7 和 32 位 x86 内核，文件、SHA-256 清单及许可证位于 `kernels/`。对应的[官方发布](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32)和[源代码](https://github.com/MetaCubeX/mihomo/tree/v1.19.32)也可查看。启用 TUN 会改变本机路由和 DNS；仅在确认后才会部署。配置检查失败或订阅格式不受支持时，安装器会在修改系统前停止。
