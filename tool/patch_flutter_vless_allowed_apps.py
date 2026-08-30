#!/usr/bin/env python3
"""Patch flutter_vless_android 1.1.5 with native allowed-app routing.

The app is pinned to flutter_vless 1.1.5. That version exposes Android's
blockedApps/addDisallowedApplication path but not addAllowedApplication.
This script applies the smallest possible Android-side extension after
`flutter pub get` so Selected-only routing stays inside the plugin's existing
VpnService instead of starting a second VPN service.
"""

from __future__ import annotations

import json
import pathlib
import sys
from urllib.parse import unquote, urlparse


PACKAGE_NAME = "flutter_vless_android"
EXPECTED_VERSION_FRAGMENT = "flutter_vless_android-1.1.5"


def fail(message: str) -> None:
    raise SystemExit(f"[flutter_vless patch] {message}")


def package_root() -> pathlib.Path:
    config_path = pathlib.Path(".dart_tool/package_config.json")
    if not config_path.is_file():
        fail(".dart_tool/package_config.json is missing; run flutter pub get first")

    data = json.loads(config_path.read_text(encoding="utf-8"))
    package = next(
        (item for item in data.get("packages", []) if item.get("name") == PACKAGE_NAME),
        None,
    )
    if package is None:
        fail(f"{PACKAGE_NAME} was not found in package_config.json")

    root_uri = package.get("rootUri", "")
    parsed = urlparse(root_uri)
    if parsed.scheme == "file":
        root = pathlib.Path(unquote(parsed.path))
    else:
        root = (config_path.parent / unquote(root_uri)).resolve()

    if EXPECTED_VERSION_FRAGMENT not in str(root):
        fail(f"expected flutter_vless_android 1.1.5, got {root}")
    return root


def replace_once(path: pathlib.Path, old: str, new: str, marker: str) -> None:
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"[flutter_vless patch] already patched: {path.name}")
        return
    if old not in text:
        fail(f"upstream source changed; expected block not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[flutter_vless patch] patched: {path.name}")


def main() -> None:
    root = package_root()
    kotlin = root / "android/src/main/kotlin/com/github/tfox/flutter_vless"

    config_path = kotlin / "xray/dto/XrayConfig.kt"
    replace_once(
        config_path,
        '''    /** List of app package names to exclude from VPN. */\n    var BLOCKED_APPS: ArrayList<String> = ArrayList(),\n''',
        '''    /** List of app package names to exclude from VPN. */\n    var BLOCKED_APPS: ArrayList<String> = ArrayList(),\n\n    /** List of app package names that are exclusively allowed into VPN. */\n    var ALLOWED_APPS: ArrayList<String> = ArrayList(),\n''',
        "var ALLOWED_APPS:",
    )

    plugin_path = kotlin / "FlutterVlessPlugin.kt"
    replace_once(
        plugin_path,
        '''    private lateinit var context: Context\n''',
        '''    private lateinit var context: Context\n    private var allowedApps: ArrayList<String> = ArrayList()\n''',
        "private var allowedApps:",
    )
    replace_once(
        plugin_path,
        '''        when (call.method) {\n            "startVless" -> {\n''',
        '''        when (call.method) {\n            "setAllowedApps" -> {\n                val requested = call.argument<ArrayList<String>>("allowed_apps") ?: ArrayList()\n                allowedApps = ArrayList(\n                    requested.map { it.trim() }.filter { it.isNotEmpty() }.distinct()\n                )\n                result.success(null)\n            }\n            "startVless" -> {\n''',
        '"setAllowedApps" ->',
    )
    replace_once(
        plugin_path,
        '''                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()\n                config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()\n''',
        '''                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()\n                config.ALLOWED_APPS = ArrayList(allowedApps)\n                config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()\n''',
        "config.ALLOWED_APPS = ArrayList(allowedApps)",
    )

    service_path = kotlin / "xray/service/XrayVPNService.kt"
    old_policy = '''          try {\n    builder.addDisallowedApplication(packageName)\n} catch (e: Exception) {\n    Log.e(TAG, "Failed to exclude app from VPN", e)\n}\n\nfor (pkg in config.BLOCKED_APPS) {\n    try {\n        builder.addDisallowedApplication(pkg)\n        Log.d(TAG, "Excluded from VPN: $pkg")\n    } catch (e: Exception) {\n        Log.e(TAG, "Failed to exclude $pkg from VPN", e)\n    }\n}\n'''
    new_policy = '''            if (config.ALLOWED_APPS.isNotEmpty()) {\n                for (pkg in config.ALLOWED_APPS) {\n                    try {\n                        builder.addAllowedApplication(pkg)\n                        Log.d(TAG, "Allowed into VPN: $pkg")\n                    } catch (e: Exception) {\n                        Log.e(TAG, "Failed to allow $pkg into VPN", e)\n                    }\n                }\n            } else {\n                try {\n                    builder.addDisallowedApplication(packageName)\n                } catch (e: Exception) {\n                    Log.e(TAG, "Failed to exclude app from VPN", e)\n                }\n\n                for (pkg in config.BLOCKED_APPS) {\n                    try {\n                        builder.addDisallowedApplication(pkg)\n                        Log.d(TAG, "Excluded from VPN: $pkg")\n                    } catch (e: Exception) {\n                        Log.e(TAG, "Failed to exclude $pkg from VPN", e)\n                    }\n                }\n            }\n'''
    replace_once(
        service_path,
        old_policy,
        new_policy,
        "builder.addAllowedApplication(pkg)",
    )

    print("[flutter_vless patch] allowed-app routing patch is ready")


if __name__ == "__main__":
    main()
