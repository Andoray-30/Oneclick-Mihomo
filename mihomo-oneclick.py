#!/usr/bin/env python3
"""Small helper for the Mihomo one-click installer."""

from __future__ import annotations

import base64
import binascii
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_json(path: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as source:
            return json.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("无法解析上游配置数据。")


def subscription_url(path: str) -> str:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        fail("订阅配置文件无法读取。")
    value = raw.strip()
    if not value or "\n" in value or "\r" in value:
        fail("订阅配置文件必须只有一条地址。")
    if not value.startswith("https://") or any(ch.isspace() for ch in value):
        fail("订阅地址必须是完整的 HTTPS 地址。")
    if '"' in value or "\\" in value:
        fail("订阅地址中包含不支持的字符；请使用 URL 编码。")
    return value


def _download_file_once(url: str, destination: str, max_bytes: int) -> None:
    if not url.startswith("https://") or max_bytes <= 0:
        fail("下载参数无效。")
    headers = {"User-Agent": "clash-verge/v2.5.8", "Accept": "*/*"}
    request = urllib.request.Request(url, headers=headers)
    path = Path(destination)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_length = response.headers.get("Content-Length")
            try:
                expected_bytes = int(content_length) if content_length else 0
            except ValueError:
                expected_bytes = 0
            if expected_bytes > max_bytes:
                fail("下载内容超过大小限制。")
            content_type = response.headers.get_content_type()
            transfer_encoding = response.headers.get("Transfer-Encoding", "未知")
            redirected = response.geturl() != url
            print(
                f"订阅 HTTP 状态：{response.status}；重定向：{'是' if redirected else '否'}；传输方式：{transfer_encoding}",
                file=sys.stderr,
                flush=True,
            )
            print(f"订阅响应类型：{content_type}", file=sys.stderr, flush=True)
            if content_type in {"text/html", "application/xhtml+xml"}:
                print("服务端标记为 HTML，将下载正文并按实际内容识别配置。", file=sys.stderr, flush=True)
            total = 0
            last_report = 0
            last_report_time = time.monotonic()
            with path.open("wb") as output:
                while True:
                    block = response.read1(min(64 * 1024, max_bytes - total + 1))
                    if not block:
                        break
                    total += len(block)
                    if total > max_bytes:
                        fail("下载内容超过大小限制。")
                    output.write(block)
                    now = time.monotonic()
                    if last_report == 0 or total - last_report >= 128 * 1024 or now - last_report_time >= 5:
                        if expected_bytes:
                            progress = min(100, total * 100 // expected_bytes)
                            message = f"订阅下载进度：{progress}%（{total // 1024} KiB）"
                        else:
                            message = f"订阅已接收：{total // 1024} KiB"
                        print(message, file=sys.stderr, flush=True)
                        last_report = total
                        last_report_time = now
            print(f"订阅下载完成：{total} 字节", file=sys.stderr, flush=True)
    except SystemExit:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise


def _download_file_with_curl(url: str, destination: str, max_bytes: int) -> None:
    path = Path(destination)
    print("正在使用 curl 下载订阅（支持 HTTP/2 和压缩响应）……", file=sys.stderr, flush=True)
    arguments = [
        "curl", "--location", "--fail", "--compressed",
        "--connect-timeout", "15", "--max-time", "180",
        "--max-filesize", str(max_bytes),
        "--user-agent", "clash-verge/v2.5.8", "--header", "Accept: */*",
        "--output", str(path),
        "--write-out", "%{http_code}\\n%{content_type}\\n%{num_redirects}\\n",
        "--progress-bar" if sys.stderr.isatty() else "--silent",
        "--show-error", "--config", "-",
    ]
    config = 'url = "' + url.replace("\\", "\\\\").replace('"', '\\"') + '"\n'
    try:
        result = subprocess.run(arguments, input=config.encode(), stdout=subprocess.PIPE, timeout=195)
        if result.returncode:
            raise OSError(f"curl 下载失败（退出码 {result.returncode}）")
        if path.stat().st_size > max_bytes:
            fail("下载内容超过大小限制。")
        metadata = result.stdout.decode(errors="replace").splitlines()
        if len(metadata) >= 3:
            print(f"订阅 HTTP 状态：{metadata[0]}；重定向次数：{metadata[2]}", file=sys.stderr, flush=True)
            print(f"订阅响应类型：{metadata[1]}（以正文解析结果为准）", file=sys.stderr, flush=True)
        print(f"订阅下载完成：{path.stat().st_size} 字节", file=sys.stderr, flush=True)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def download_file(url: str, destination: str, max_bytes: int) -> None:
    if not url.startswith("https://") or max_bytes <= 0:
        fail("下载参数无效。")
    downloader = _download_file_with_curl if shutil.which("curl") else _download_file_once
    if downloader is _download_file_once:
        print("未安装 curl，使用 Python 内置下载器……", file=sys.stderr, flush=True)
    for attempt in range(1, 4):
        try:
            downloader(url, destination, max_bytes)
            return
        except Exception as exc:
            print(f"订阅网络读取失败：{type(exc).__name__}（第 {attempt}/3 次）。", file=sys.stderr, flush=True)
            if attempt == 3:
                fail("HTTPS 下载重试后仍失败，请稍后重新运行。")
            print("正在重新连接订阅服务器……", file=sys.stderr, flush=True)
            time.sleep(1)


def download_command(argv: list[str]) -> None:
    if len(argv) == 5 and argv[1] == "download-subscription":
        try:
            max_bytes = int(argv[4])
        except ValueError:
            fail("下载大小限制无效。")
        download_file(subscription_url(argv[2]), argv[3], max_bytes)
    elif len(argv) == 3 and argv[1] == "validate-subscription":
        subscription_url(argv[2])
    else:
        fail("内部下载参数无效。")


def looks_like_mihomo_profile(text: str) -> bool:
    if re.search(r"(?m)^[\"']?(?:proxies|proxy-providers)[\"']?\s*:", text):
        return True
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return False
    return isinstance(value, dict) and ("proxies" in value or "proxy-providers" in value)


def normalize_subscription(source_path: str, destination_path: str) -> None:
    try:
        raw = Path(source_path).read_bytes()
    except OSError:
        fail("下载的订阅配置无法读取。")
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("订阅响应不是 UTF-8 文本；请确认订阅服务提供 Mihomo/Clash YAML 格式。")

    if re.match(r"\s*(?:<!doctype\s+html\b|<html\b)", text, re.IGNORECASE):
        fail("订阅正文确实是 HTML 网页，未找到 Mihomo/Clash YAML 配置。")

    if not looks_like_mihomo_profile(text):
        compact = re.sub(r"\s+", "", text)
        if compact and re.fullmatch(r"[A-Za-z0-9_+/=-]+", compact):
            try:
                padding = "=" * ((-len(compact)) % 4)
                decoded = base64.b64decode(compact + padding, altchars=b"-_", validate=True).decode("utf-8")
            except (binascii.Error, ValueError, UnicodeDecodeError):
                decoded = ""
            if decoded and looks_like_mihomo_profile(decoded):
                text = decoded
                print("检测到 Base64 包装的 Mihomo/Clash YAML，已自动解码。")

    try:
        Path(destination_path).write_text(text, encoding="utf-8")
    except OSError:
        fail("临时订阅配置无法写入。")


def profile_nodes(path: str) -> list[dict[str, Any]]:
    config = read_json(path)
    if not isinstance(config, dict):
        if isinstance(config, str):
            if config.lstrip().lower().startswith(("<!doctype html", "<html")):
                fail("订阅链接返回了网页内容，常见于登录页或错误页；请检查订阅权限和返回格式。")
            fail("订阅链接返回的是文本而非配置对象；常见原因是协议节点列表或 Base64 节点订阅。请改用 Mihomo/Clash YAML 订阅。")
        fail("订阅 YAML 的根节点不是配置对象；请使用 Mihomo/Clash YAML 订阅。")

    if "proxies" not in config:
        if "proxy-providers" in config:
            fail("订阅只包含 proxy-providers，没有可直接选择的 proxies 节点列表；请使用包含 proxies 列表的 Mihomo/Clash 配置。")
        safe_keys = [key for key in config if isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,40}", key)]
        summary = "、".join(safe_keys[:12])
        detail = f"（检测到字段：{summary}）" if summary else ""
        fail(f"订阅内容可解析，但没有顶层 proxies 节点列表{detail}；请确认订阅输出格式为 Mihomo/Clash YAML。")
    if not isinstance(config["proxies"], list):
        fail("订阅存在 proxies 字段，但它不是节点列表；请检查订阅转换格式。")

    nodes = config["proxies"]
    if not nodes:
        fail("订阅中的 proxies 列表为空；请检查订阅套餐或转换格式。")
    names: list[dict[str, Any]] = []
    seen: set[str] = set()
    for node in nodes:
        if not isinstance(node, dict) or not isinstance(node.get("name"), str) or not node["name"]:
            fail("上游配置中有节点缺少有效名称。")
        name = node["name"]
        if name in seen:
            fail("上游配置包含重复节点名称，无法安全地按名称选择。")
        seen.add(name)
        names.append(node)
    if not names:
        fail("上游配置中没有可选择的节点。")
    return names


def list_nodes(path: str) -> None:
    for index, node in enumerate(profile_nodes(path), start=1):
        # JSON escaping keeps control characters from being interpreted by the terminal.
        print(f"{index}\t{json.dumps(node['name'], ensure_ascii=False)}")


def configure_profile(path: str, index_text: str) -> None:
    config = read_json(path)
    nodes = profile_nodes(path)
    try:
        index = int(index_text) - 1
    except ValueError:
        fail("节点序号无效。")
    if index < 0 or index >= len(nodes):
        fail("节点序号超出范围。")
    selected_name = nodes[index]["name"]

    # Keep the subscription's rules and rule-providers. Groups that can reach
    # the selected node are narrowed to a single path ending at that node.
    groups = config.get("proxy-groups", [])
    if groups is None:
        groups = []
    if not isinstance(groups, list):
        fail("上游配置的 proxy-groups 格式不受支持。")

    by_name: dict[str, dict[str, Any]] = {}
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("name"), str):
            fail("上游配置中有 proxy-group 缺少名称。")
        name = group["name"]
        if name in by_name:
            fail("上游配置包含重复的 proxy-group 名称。")
        by_name[name] = group

    def next_hop(group_name: str, trail: frozenset[str]) -> str | None:
        if group_name == selected_name or group_name in trail:
            return None
        group = by_name.get(group_name)
        if group is None:
            return None
        children = group.get("proxies", [])
        if not isinstance(children, list):
            return None
        for child in children:
            if not isinstance(child, str):
                continue
            if child == selected_name:
                return child
            if next_hop(child, trail | {group_name}) is not None:
                return child
        return None

    for name, group in by_name.items():
        hop = next_hop(name, frozenset())
        if hop is None:
            continue
        group["type"] = "select"
        group["proxies"] = [hop]
        for key in ("use", "filter", "exclude-filter", "include-all", "include-all-proxies"):
            group.pop(key, None)

    selected_group = "MIHOMO-ONECLICK"
    suffix = 1
    while selected_group in by_name:
        suffix += 1
        selected_group = f"MIHOMO-ONECLICK-{suffix}"
    groups.append({"name": selected_group, "type": "select", "proxies": [selected_name]})
    config["proxy-groups"] = groups

    rules = config.get("rules", [])
    if rules is None:
        rules = []
    if not isinstance(rules, list):
        fail("上游配置的 rules 格式不受支持。")

    final_rule_found = False
    for rule_index, rule in enumerate(rules):
        if isinstance(rule, dict):
            rule_text = rule.get("rule")
            if isinstance(rule_text, str) and rule_text.split(",", 1)[0].strip().upper() in {"MATCH", "FINAL"}:
                fail("上游使用了无法安全改写的结构化 MATCH/FINAL 规则。")
            fail("上游使用了无法安全混合处理的结构化规则。")
        if not isinstance(rule, str):
            fail("上游规则列表包含无法安全改写的项目。")
        kind = rule.split(",", 1)[0].strip().upper()
        if kind not in {"MATCH", "FINAL"}:
            continue
        fields = rule.split(",")
        if len(fields) == 1:
            fields.append(selected_group)
        else:
            fields[-1] = selected_group
        rules[rule_index] = ",".join(fields)
        final_rule_found = True

    if not final_rule_found:
        rules.append(f"MATCH,{selected_group}")
    config["rules"] = rules
    config["mode"] = "rule"

    config["tun"] = {
        "enable": True,
        "stack": "mips",
        "auto-route": True,
        "auto-detect-interface": True,
        "dns-hijack": ["any:53"],
    }

    dns = config.get("dns")
    if not isinstance(dns, dict):
        dns = {}
    dns["enable"] = True
    if not dns.get("default-nameserver"):
        dns["default-nameserver"] = ["223.5.5.5", "119.29.29.29"]
    if not dns.get("nameserver"):
        dns["nameserver"] = ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"]
    if not dns.get("proxy-server-nameserver"):
        dns["proxy-server-nameserver"] = ["223.5.5.5", "119.29.29.29"]
    config["dns"] = dns

    try:
        json.dump(config, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    except (TypeError, ValueError):
        fail("上游配置中包含无法转换的 YAML 数据。")


def main(argv: list[str]) -> None:
    if len(argv) >= 2 and argv[1] in {"download-subscription", "validate-subscription"}:
        download_command(argv)
    elif len(argv) == 4 and argv[1] == "normalize-subscription":
        normalize_subscription(argv[2], argv[3])
    elif len(argv) == 3 and argv[1] == "list-nodes":
        list_nodes(argv[2])
    elif len(argv) == 4 and argv[1] == "configure":
        configure_profile(argv[2], argv[3])
    else:
        fail("内部调用参数无效。")


if __name__ == "__main__":
    main(sys.argv)
