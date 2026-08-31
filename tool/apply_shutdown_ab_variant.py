from pathlib import Path
import sys

SERVICE = Path('third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt')
CORE = Path('third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/core/XrayCoreManager.kt')
DART = Path('lib/logic/vpn_connection.dart')


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f'{label}: expected source block not found in {path}')
    path.write_text(text.replace(old, new, 1))
    print(f'[AB] {label}')


def fd_gate_off() -> None:
    replace_once(
        SERVICE,
        '''        startTun2socks(config, generation)\n        if (!sendFdAndWait(generation)) {\n            throw IllegalStateException("TUN file descriptor was not delivered to tun2socks")\n        }\n        AppConfigs.FD_DELIVERED = true\n''',
        '''        startTun2socks(config, generation)\n        val fdDeliveredForAbTest = sendFdAndWait(generation)\n        if (!fdDeliveredForAbTest) {\n            Log.w(TAG, "AB FD_GATE_OFF: continuing after FD handoff failure")\n        }\n        AppConfigs.FD_DELIVERED = true\n''',
        'FD_GATE_OFF',
    )


def socks_auth_off() -> None:
    replace_once(
        SERVICE,
        '''        config.LOCAL_SOCKS5_PORT = findFreePort()\n        config.LOCAL_API_PORT = 0\n        config.LOCAL_HTTP_PORT = 0\n        config.LOCAL_SOCKS5_USER = "rv_${randomToken(12)}"\n        config.LOCAL_SOCKS5_PASS = randomToken(24)\n''',
        '''        config.LOCAL_SOCKS5_PORT = 10807\n        config.LOCAL_API_PORT = 0\n        config.LOCAL_HTTP_PORT = 0\n        config.LOCAL_SOCKS5_USER = ""\n        config.LOCAL_SOCKS5_PASS = ""\n''',
        'SOCKS_AUTH_OFF service isolation',
    )
    replace_once(
        SERVICE,
        '''        val proxy =\n            "socks5://${config.LOCAL_SOCKS5_USER}:${config.LOCAL_SOCKS5_PASS}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}"\n''',
        '''        val proxy = if (config.LOCAL_SOCKS5_USER.isEmpty() || config.LOCAL_SOCKS5_PASS.isEmpty()) {\n            "socks5://127.0.0.1:${config.LOCAL_SOCKS5_PORT}"\n        } else {\n            "socks5://${config.LOCAL_SOCKS5_USER}:${config.LOCAL_SOCKS5_PASS}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}"\n        }\n''',
        'SOCKS_AUTH_OFF tun2socks URI',
    )
    replace_once(
        CORE,
        '''        if (config.LOCAL_SOCKS5_PORT <= 0 ||\n            config.LOCAL_SOCKS5_USER.isEmpty() ||\n            config.LOCAL_SOCKS5_PASS.isEmpty()\n        ) {\n            throw IllegalStateException("Isolated SOCKS5 credentials are required")\n        }\n''',
        '''        if (config.LOCAL_SOCKS5_PORT <= 0) {\n            throw IllegalStateException("Local SOCKS5 port is required")\n        }\n''',
        'SOCKS_AUTH_OFF core credential requirement',
    )
    replace_once(
        CORE,
        '''        val socksSettings = JSONObject()\n            .put("auth", "password")\n            .put("udp", true)\n            .put("ip", "127.0.0.1")\n            .put(\n                "users",\n                JSONArray().put(\n                    JSONObject()\n                        .put("user", config.LOCAL_SOCKS5_USER)\n                        .put("pass", config.LOCAL_SOCKS5_PASS)\n                )\n            )\n''',
        '''        val socksSettings = JSONObject()\n            .put(\n                "auth",\n                if (config.LOCAL_SOCKS5_USER.isEmpty() || config.LOCAL_SOCKS5_PASS.isEmpty()) "noauth" else "password"\n            )\n            .put("udp", true)\n            .put("ip", "127.0.0.1")\n        if (config.LOCAL_SOCKS5_USER.isNotEmpty() && config.LOCAL_SOCKS5_PASS.isNotEmpty()) {\n            socksSettings.put(\n                "users",\n                JSONArray().put(\n                    JSONObject()\n                        .put("user", config.LOCAL_SOCKS5_USER)\n                        .put("pass", config.LOCAL_SOCKS5_PASS)\n                )\n            )\n        }\n''',
        'SOCKS_AUTH_OFF Xray inbound',
    )
    replace_once(
        CORE,
        '''        if (port <= 0 || user.isEmpty() || pass.isEmpty()) return false\n        var socket: Socket? = null\n        return try {\n            socket = Socket()\n            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), timeoutMs)\n            socket.soTimeout = timeoutMs\n            val input = socket.getInputStream()\n            val output = socket.getOutputStream()\n\n            output.write(byteArrayOf(0x05, 0x01, 0x02))\n            output.flush()\n            val greeting = readExactly(input, 2)\n            if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != 0x02) return false\n            val u = user.toByteArray(Charsets.UTF_8)\n            val p = pass.toByteArray(Charsets.UTF_8)\n            if (u.isEmpty() || u.size > 255 || p.isEmpty() || p.size > 255) return false\n            output.write(byteArrayOf(0x01, u.size.toByte()))\n            output.write(u)\n            output.write(byteArrayOf(p.size.toByte()))\n            output.write(p)\n            output.flush()\n            val auth = readExactly(input, 2)\n            if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false\n''',
        '''        if (port <= 0) return false\n        var socket: Socket? = null\n        return try {\n            socket = Socket()\n            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), timeoutMs)\n            socket.soTimeout = timeoutMs\n            val input = socket.getInputStream()\n            val output = socket.getOutputStream()\n\n            val noAuth = user.isEmpty() || pass.isEmpty()\n            output.write(byteArrayOf(0x05, 0x01, if (noAuth) 0x00 else 0x02))\n            output.flush()\n            val greeting = readExactly(input, 2)\n            val expectedMethod = if (noAuth) 0x00 else 0x02\n            if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != expectedMethod) return false\n            if (!noAuth) {\n                val u = user.toByteArray(Charsets.UTF_8)\n                val p = pass.toByteArray(Charsets.UTF_8)\n                if (u.isEmpty() || u.size > 255 || p.isEmpty() || p.size > 255) return false\n                output.write(byteArrayOf(0x01, u.size.toByte()))\n                output.write(u)\n                output.write(byteArrayOf(p.size.toByte()))\n                output.write(p)\n                output.flush()\n                val auth = readExactly(input, 2)\n                if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false\n            }\n''',
        'SOCKS_AUTH_OFF probe compatibility',
    )


def socks_watchdog_off() -> None:
    replace_once(
        SERVICE,
        '''                    if (!waitForSocks(config, generation)) {\n                        throw IllegalStateException("Local SOCKS5 did not become ready")\n                    }\n                    AppConfigs.SOCKS_READY = true\n''',
        '''                    if (!waitForSocks(config, generation)) {\n                        Log.w(TAG, "AB SOCKS_WATCHDOG_OFF: proxy SOCKS probe failed; continuing")\n                    }\n                    AppConfigs.SOCKS_READY = true\n''',
        'SOCKS_WATCHDOG_OFF proxy path',
    )
    replace_once(
        SERVICE,
        '''        if (!waitForSocks(config, generation)) {\n            throw IllegalStateException("Authenticated SOCKS5 ingress did not become ready")\n        }\n        AppConfigs.SOCKS_READY = true\n''',
        '''        if (!waitForSocks(config, generation)) {\n            Log.w(TAG, "AB SOCKS_WATCHDOG_OFF: TUN SOCKS probe failed; continuing")\n        }\n        AppConfigs.SOCKS_READY = true\n''',
        'SOCKS_WATCHDOG_OFF TUN path',
    )


def tun2socks_monitor_off() -> None:
    replace_once(
        SERVICE,
        '''                    terminateService(\n                        "tun2socks exited unexpectedly",\n                        preserveConfig = true,\n                    )\n''',
        '''                    Log.w(TAG, "AB TUN2SOCKS_MONITOR_OFF: not terminating VPN after tun2socks exit")\n''',
        'TUN2SOCKS_MONITOR_OFF exit',
    )
    replace_once(
        SERVICE,
        '''                    terminateService(\n                        "tun2socks monitor failed",\n                        preserveConfig = true,\n                    )\n''',
        '''                    Log.w(TAG, "AB TUN2SOCKS_MONITOR_OFF: not terminating VPN after monitor failure")\n''',
        'TUN2SOCKS_MONITOR_OFF monitor error',
    )


def dart_readiness_stop_off() -> None:
    replace_once(
        DART,
        '''      _setStatus(VpnStatus.connecting, 'Verifying VPN data path…');\n      if (!await _waitForNativeConnected()) {\n        throw StateError('Native TUN/FD/SOCKS readiness was not confirmed');\n      }\n''',
        '''      _setStatus(VpnStatus.connecting, 'Verifying VPN data path…');\n      final abNativeReady = await _waitForNativeConnected();\n      if (!abNativeReady) {\n        debugPrint('[AB] DART_READINESS_STOP_OFF: native readiness false-negative ignored');\n      }\n''',
        'DART_READINESS_STOP_OFF',
    )


def generation_guard_off() -> None:
    replace_once(
        SERVICE,
        '''        if (generation != currentGeneration || stopping) {\n            established.close()\n            throw IllegalStateException("VPN startup was superseded")\n        }\n''',
        '''        // AB GENERATION_GUARD_OFF: do not close a newly established TUN\n        // solely because startup generation/stopping state changed mid-flight.\n''',
        'GENERATION_GUARD_OFF establish guard',
    )
    replace_once(
        SERVICE,
        '''            while (tries < 10 && generation == currentGeneration && !stopping) {\n''',
        '''            while (tries < 10) {\n''',
        'GENERATION_GUARD_OFF FD loop',
    )
    replace_once(
        SERVICE,
        '''        if (!delivered || generation != currentGeneration || stopping) return false\n''',
        '''        if (!delivered) return false\n''',
        'GENERATION_GUARD_OFF FD result',
    )
    replace_once(
        SERVICE,
        '''            if (generation != currentGeneration || stopping || !XrayCoreManager.isXrayRunning()) return false\n''',
        '''            if (!XrayCoreManager.isXrayRunning()) return false\n''',
        'GENERATION_GUARD_OFF SOCKS loop',
    )


VARIANTS = {
    'FD_GATE_OFF': fd_gate_off,
    'SOCKS_AUTH_OFF': socks_auth_off,
    'SOCKS_WATCHDOG_OFF': socks_watchdog_off,
    'TUN2SOCKS_MONITOR_OFF': tun2socks_monitor_off,
    'DART_READINESS_STOP_OFF': dart_readiness_stop_off,
    'GENERATION_GUARD_OFF': generation_guard_off,
}

if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
    raise SystemExit('usage: apply_shutdown_ab_variant.py ' + '|'.join(VARIANTS))

variant = sys.argv[1]
VARIANTS[variant]()
print(f'[AB] applied exactly one shutdown isolation variant: {variant}')
