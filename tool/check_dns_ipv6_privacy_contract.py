#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from urllib.parse import urlparse
from urllib.request import url2pathname

ROOT = pathlib.Path(__file__).resolve().parents[1]


def fail(message: str) -> "NoReturn":
    print(f"[FAIL] DNS/IPv6 privacy contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def text(path: str) -> str:
    target = ROOT / path
    if not target.is_file() or target.is_symlink():
        fail(f"missing regular source file: {path}")
    return target.read_text(encoding="utf-8")


pubspec = text("pubspec.yaml")
lock = text("pubspec.lock")
vpn = text("lib/logic/vpn_connection.dart")
hivemind = text("lib/logic/hivemind_service.dart")
privacy = text("lib/logic/network_privacy.dart")
manifest = text("android/app/src/main/AndroidManifest.xml")

if not re.search(r"(?m)^  flutter_vless: 1\.1\.6$", pubspec):
    fail("flutter_vless must be exactly pinned to 1.1.6")

expected_packages = {
    "flutter_vless": (
        "1.1.6",
        "ccda63e67218c99f134a338d904264b9772bf289966fafb5067801d547b27f51",
    ),
    "flutter_vless_android": (
        "1.1.6",
        "9dfcdfe74ba6c0c4f3569cc9c1089e0011f36ee94c69ce3960067dc02115e245",
    ),
}

for package, (version, sha256) in expected_packages.items():
    block = re.search(
        rf"(?ms)^  {re.escape(package)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_]+:|^sdks:)",
        lock,
    )
    if block is None:
        fail(f"{package} lock entry is missing")
    body = block.group("body")
    if not re.search(rf'(?m)^    version: "{re.escape(version)}"$', body):
        fail(f"{package} lock entry must be exactly {version}")
    if not re.search(rf'(?m)^      sha256: "?{sha256}"?$', body):
        fail(f"{package} lock entry must retain the reviewed pub.dev content hash")
    if '      url: "https://pub.dev"' not in body or "    source: hosted" not in body:
        fail(f"{package} must remain a hosted pub.dev dependency")

# Run this contract only after locked dependency resolution. We inspect the
# actual resolved native source as well as the lockfile identity.
package_config_path = ROOT / ".dart_tool/package_config.json"
if not package_config_path.is_file() or package_config_path.is_symlink():
    fail("resolved package_config.json is missing; run this after locked pub get")
try:
    package_config = json.loads(package_config_path.read_text(encoding="utf-8"))
except (json.JSONDecodeError, OSError) as error:
    fail(f"resolved package_config.json is invalid: {error}")

android_entry = next(
    (
        entry
        for entry in package_config.get("packages", [])
        if entry.get("name") == "flutter_vless_android"
    ),
    None,
)
if android_entry is None:
    fail("resolved flutter_vless_android is missing from package_config.json")

root_uri = android_entry.get("rootUri")
if not isinstance(root_uri, str):
    fail("resolved flutter_vless_android rootUri is invalid")
parsed_root = urlparse(root_uri)
if parsed_root.scheme != "file":
    fail("resolved flutter_vless_android must come from the hosted package cache")
resolved_root_text = url2pathname(parsed_root.path)
if os.name == "nt" and re.match(r"^[/\\][A-Za-z]:", resolved_root_text):
    resolved_root_text = resolved_root_text[1:]
android_root = pathlib.Path(resolved_root_text)
if android_root.name != "flutter_vless_android-1.1.6":
    fail(f"unexpected resolved Android package root: {android_root}")
if not android_root.is_dir() or android_root.is_symlink():
    fail("resolved flutter_vless_android root must be a real directory")

kotlin_base = android_root / "android/src/main/kotlin/com/github/tfox/flutter_vless/xray"
service_path = kotlin_base / "service/XrayVPNService.kt"
dns_policy_path = kotlin_base / "core/AndroidTunnelDnsPolicy.kt"
protector_path = kotlin_base / "service/XraySocketProtector.kt"
for source_path in (service_path, dns_policy_path, protector_path):
    if not source_path.is_file() or source_path.is_symlink():
        fail(f"reviewed Android dependency source is missing: {source_path}")

service_source = service_path.read_text(encoding="utf-8")
dns_policy_source = dns_policy_path.read_text(encoding="utf-8")
protector_source = protector_path.read_text(encoding="utf-8")

for needle in (
    'it.allowPhysicalDnsForEndpointNames(if (current.ANDROID_DNS_POLICY == "proxy") emptySet() else null)',
    '.addAddress("26.26.26.1", 30).addRoute("0.0.0.0", 0)',
    "current.BLOCKED_APPS.forEach",
    "dnsServers.forEach { builder.addDnsServer(it) }",
    "stopWorkers() // TUN remains installed throughout backoff, including persistent failure.",
):
    if needle not in service_source:
        fail(f"resolved Android VPN service lost a reviewed fail-closed invariant: {needle}")

for forbidden in ("allowFamily(", "addDisallowedApplication(packageName)"):
    if forbidden in service_source:
        fail(f"resolved Android VPN service reintroduced a bypass primitive: {forbidden}")

for needle in (
    'const val VIRTUAL_SERVER = "198.18.0.2"',
    'require(policy == "config" || policy == "proxy")',
    "return Prepared(config.toString(), listOf(VIRTUAL_SERVER), names, addresses)",
    '.put("qType", "28").put("rCode", 0)',
    '.put("streamSettings", JSONObject().put("sockopt", JSONObject().put("dialerProxy", selectedTag)))',
    '.put("queryStrategy", "UseIP").put("disableFallback", true)',
    'sockopt.put("domainStrategy", "ForceIP")',
):
    if needle not in dns_policy_source:
        fail(f"resolved protected-DNS implementation lost a reviewed invariant: {needle}")

for needle in (
    "if (!XrayPhysicalDns.isQueryAllowed(query, permittedNames)) return@use",
    "val network = physicalNetwork() ?: return@use",
    "caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)",
):
    if needle not in protector_source:
        fail(f"resolved socket protector lost a reviewed DNS guard: {needle}")

required_vpn = (
    "blockedApps: const <String>[]",
    "bypassSubnets: const <String>[]",
    "proxyOnly: false",
    "androidDnsPolicy: AndroidDnsPolicy.proxy",
)
for needle in required_vpn:
    if vpn.count(needle) != 1:
        fail(f"managed VPN start must contain exactly one {needle!r}")

if "AndroidDnsPolicy.config" in vpn:
    fail("managed ReVoltVPN start must never select the unprotected Android DNS policy")

for needle in (
    "NetworkPrivacy.vlessAuthorityHost(",
    "NetworkPrivacy.vlessPort(",
    "'vless://$vlessUuid@$vlessHost:$vlessPort'",
):
    if needle not in hivemind:
        fail(f"status-to-VLESS transport validation is missing: {needle}")

for needle in (
    "VLESS endpoint must be a bare IP literal.",
    "value.contains('%')",
    "static bool _allowedIpv4(List<int> octets)",
    "if (a == 0 || a == 10 || a == 127 || a >= 224)",
    "a == 100 && b >= 64 && b <= 127",
    "a == 172 && b >= 16 && b <= 31",
    "a == 192 && b == 168",
    "a == 198 && (b == 18 || b == 19)",
    "a == 203 && b == 0 && c == 113",
    "static bool _allowedIpv6(List<int> words)",
    "(words[0] & 0xe000) != 0x2000",
    "words[1] == 0x0db8",
    "words[0] == 0x2002",
    "words[0] == 0x3fff && (words[1] & 0xf000) == 0",
    "return '[$value]'",
    "candidate is! int || candidate < 1 || candidate > 65535",
):
    if needle not in privacy:
        fail(f"literal endpoint fail-closed rule is missing: {needle}")

if 'android:usesCleartextTraffic="false"' not in manifest:
    fail("Android application must continue rejecting cleartext traffic")

print(
    "[PASS] Android VPN uses protected proxy DNS, no managed app/subnet bypass, "
    "literal transport endpoints, and the resolved 1.1.6 native source retains "
    "the reviewed fail-closed DNS/IPv6 invariants."
)
