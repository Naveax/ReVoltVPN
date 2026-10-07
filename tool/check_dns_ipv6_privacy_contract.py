#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

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
    "octets[0] == 127",
    "octets[0] == 169 && octets[1] == 254",
    "octets[0] >= 224 && octets[0] <= 239",
    "static bool _allowedIpv6(List<int> words)",
    "(words[0] & 0xff00) == 0xff00",
    "(words[0] & 0xffc0) == 0xfe80",
    "words[5] == 0xffff",
    "return '[$value]'",
    "candidate is! int || candidate < 1 || candidate > 65535",
):
    if needle not in privacy:
        fail(f"literal endpoint fail-closed rule is missing: {needle}")

if 'android:usesCleartextTraffic="false"' not in manifest:
    fail("Android application must continue rejecting cleartext traffic")

print(
    "[PASS] Android VPN uses protected proxy DNS, has no managed app/subnet bypass, "
    "and accepts only literal IPv4/IPv6 VLESS transport endpoints."
)
