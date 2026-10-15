#!/usr/bin/env python3
"""Small helper for the Mihomo one-click installer."""

from __future__ import annotations

import json
import sys
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


def download_file(url: str, destination: str, max_bytes: int, accept_github: bool = False) -> None:
    if not url.startswith("https://") or max_bytes <= 0:
        fail("下载参数无效。")
    headers = {"User-Agent": "mihomo-oneclick-installer"}
    if accept_github:
        headers["Accept"] = "application/vnd.github+json"
    request = urllib.request.Request(url, headers=headers)
    path = Path(destination)
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            content_length = response.headers.get("Content-Length")
            if content_length and int(content_length) > max_bytes:
                fail("下载内容超过大小限制。")
            total = 0
            with path.open("wb") as output:
                while True:
                    block = response.read(min(1024 * 1024, max_bytes - total + 1))
                    if not block:
                        break
                    total += len(block)
                    if total > max_bytes:
                        fail("下载内容超过大小限制。")
                    output.write(block)
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
        fail("HTTPS 下载失败；已隐藏远端地址和响应内容。")


def download_command(argv: list[str]) -> None:
    if len(argv) == 6 and argv[1] == "download":
        try:
            max_bytes = int(argv[4])
        except ValueError:
            fail("下载大小限制无效。")
        download_file(argv[2], argv[3], max_bytes, accept_github=argv[5] == "github")
    elif len(argv) == 5 and argv[1] == "download-subscription":
        try:
            max_bytes = int(argv[4])
        except ValueError:
            fail("下载大小限制无效。")
        download_file(subscription_url(argv[2]), argv[3], max_bytes)
    elif len(argv) == 3 and argv[1] == "validate-subscription":
        subscription_url(argv[2])
    else:
        fail("内部下载参数无效。")


def release_asset(metadata_path: str, repository: str, platform: str) -> None:
    metadata = read_json(metadata_path)
    if not isinstance(metadata, dict):
        fail("无法读取官方发布信息。")

    tag = metadata.get("tag_name")
    assets = metadata.get("assets")
    if not isinstance(tag, str) or not isinstance(assets, list):
        fail("官方发布信息格式异常。")

    if repository == "MetaCubeX/mihomo":
        if platform == "amd64":
            expected_names = [
                f"mihomo-linux-amd64-compatible-{tag}.gz",
                f"mihomo-linux-amd64-v1-{tag}.gz",
            ]
        elif platform in {"arm64", "armv7", "386"}:
            expected_names = [f"mihomo-linux-{platform}-{tag}.gz"]
        else:
            fail("此 CPU 架构没有对应的 Mihomo 官方包。")
    elif repository == "mikefarah/yq":
        if platform not in {"amd64", "arm64", "arm", "386"}:
            fail("此 CPU 架构没有对应的 YAML 解析工具。")
        expected_names = [f"yq_linux_{platform}"]
    else:
        fail("不支持的官方发布仓库。")

    selected = None
    for expected in expected_names:
        selected = next(
            (asset for asset in assets if isinstance(asset, dict) and asset.get("name") == expected),
            None,
        )
        if selected is not None:
            break

    if selected is None:
        fail("官方最新版本中找不到适合此系统的包。")

    url = selected.get("browser_download_url")
    digest = selected.get("digest")
    required_prefix = f"https://github.com/{repository}/releases/download/"
    if (
        not isinstance(url, str)
        or not url.startswith(required_prefix)
        or not isinstance(digest, str)
        or not digest.startswith("sha256:")
    ):
        fail("官方发布缺少可验证的 SHA-256 信息，已停止下载。")

    print(f"{url}\t{digest[len('sha256:'):]}")


def profile_nodes(path: str) -> list[dict[str, Any]]:
    config = read_json(path)
    if not isinstance(config, dict) or not isinstance(config.get("proxies"), list):
        fail("订阅不是包含 proxies 节点列表的 Mihomo/Clash YAML 配置。")

    nodes = config["proxies"]
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
    if len(argv) >= 2 and argv[1] in {"download", "download-subscription", "validate-subscription"}:
        download_command(argv)
    elif len(argv) >= 2 and argv[1] == "release-asset" and len(argv) == 5:
        release_asset(argv[2], argv[3], argv[4])
    elif len(argv) == 3 and argv[1] == "list-nodes":
        list_nodes(argv[2])
    elif len(argv) == 4 and argv[1] == "configure":
        configure_profile(argv[2], argv[3])
    else:
        fail("内部调用参数无效。")


if __name__ == "__main__":
    main(sys.argv)
