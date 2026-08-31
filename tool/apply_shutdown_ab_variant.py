from pathlib import Path
import sys

SERVICE = Path('third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt')
CORE = Path('third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/core/XrayCoreManager.kt')
DART = Path('lib/logic/vpn_connection.dart')

variant = sys.argv[1] if len(sys.argv) > 1 else ''
allowed = {
    'no-fd-gate',
    'legacy-socks',
    'no-socks-watchdog',
    'no-tun2socks-exit-kill',
    'no-dart-readiness-cleanup',
    'no-generation-lifecycle-guard',
}
if variant not in allowed:
    raise SystemExit(f'Unknown A/B variant: {variant}')


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f'{label}: expected source block not found in {path}')
    path.write_text(text.replace(old, new, 1))
    print(f'[{variant}] {label}')


if variant == 'no-fd-gate':
    replace_once(
        SERVICE,
        '''        startTun2socks(config, generation)\n        if (!sendFdAndWait(generation)) {\n            throw IllegalStateException("TUN file descriptor was not delivered to tun2socks")\n        }\n        AppConfigs.FD_DELIVERED = true\n        XrayCoreManager.sendStateBroadcast(this)\n''',
        '''        startTun2socks(config, generation)\n        val abFdDelivered = sendFdAndWait(generation)\n        if (!abFdDelivered) {\n            Log.w(TAG, "A/B no-fd-gate: ignoring FD handoff failure")\n        }\n        // Diagnostic variant: disable only the FD fail-closed gate.\n        AppConfigs.FD_DELIVERED = true\n        XrayCoreManager.sendStateBroadcast(this)\n''',
        'disabled FD fail-closed gate',
    )

elif variant == 'legacy-socks':
    replace_once(
        SERVICE,
        '''    private fun prepareRuntimeIsolation(config: XrayConfig) {\n        config.LOCAL_SOCKS5_PORT = findFreePort()\n        config.LOCAL_API_PORT = 0\n        config.LOCAL_HTTP_PORT = 0\n        config.LOCAL_SOCKS5_USER = "rv_${randomToken(12)}"\n        config.LOCAL_SOCKS5_PASS = randomToken(24)\n        File(filesDir, "sock_path").delete()\n    }\n''',
        '''    private fun prepareRuntimeIsolation(config: XrayConfig) {\n        // Diagnostic variant: restore the 3.3.5-style fixed no-auth local SOCKS.\n        config.LOCAL_SOCKS5_PORT = 10807\n        config.LOCAL_API_PORT = 0\n        config.LOCAL_HTTP_PORT = 0\n        config.LOCAL_SOCKS5_USER = ""\n        config.LOCAL_SOCKS5_PASS = ""\n        File(filesDir, "sock_path").delete()\n    }\n''',
        'restored fixed no-auth SOCKS parameters',
    )
    replace_once(
        SERVICE,
        '''        val proxy =\n            "socks5://${config.LOCAL_SOCKS5_USER}:${config.LOCAL_SOCKS5_PASS}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}"\n''',
        '''        val proxy = "socks5://127.0.0.1:${config.LOCAL_SOCKS5_PORT}"\n''',
        'restored no-auth tun2socks URI',
    )
    replace_once(
        CORE,
        '''        if (config.LOCAL_SOCKS5_PORT <= 0 ||\n            config.LOCAL_SOCKS5_USER.isEmpty() ||\n            config.LOCAL_SOCKS5_PASS.isEmpty()\n        ) {\n            throw IllegalStateException("Isolated SOCKS5 credentials are required")\n        }\n''',
        '''        if (config.LOCAL_SOCKS5_PORT <= 0) {\n            throw IllegalStateException("Local SOCKS5 port is required")\n        }\n''',
        'removed credential requirement',
    )
    replace_once(
        CORE,
        '''        val socksSettings = JSONObject()\n            .put("auth", "password")\n            .put("udp", true)\n            .put("ip", "127.0.0.1")\n            .put(\n                "users",\n                JSONArray().put(\n                    JSONObject()\n                        .put("user", config.LOCAL_SOCKS5_USER)\n                        .put("pass", config.LOCAL_SOCKS5_PASS)\n                )\n            )\n''',
        '''        val socksSettings = JSONObject()\n            .put("auth", "noauth")\n            .put("udp", true)\n            .put("ip", "127.0.0.1")\n''',
        'restored Xray SOCKS noauth inbound',
    )
    replace_once(
        CORE,
        '''        if (port <= 0 || user.isEmpty() || pass.isEmpty()) return false\n        var socket: Socket? = null\n        return try {\n            socket = Socket()\n            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), timeoutMs)\n            socket.soTimeout = timeoutMs\n            val input = socket.getInputStream()\n            val output = socket.getOutputStream()\n\n            output.write(byteArrayOf(0x05, 0x01, 0x02))\n            output.flush()\n            val greeting = readExactly(input, 2)\n            if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != 0x02) return false\n            val u = user.toByteArray(Charsets.UTF_8)\n            val p = pass.toByteArray(Charsets.UTF_8)\n            if (u.isEmpty() || u.size > 255 || p.isEmpty() || p.size > 255) return false\n            output.write(byteArrayOf(0x01, u.size.toByte()))\n            output.write(u)\n            output.write(byteArrayOf(p.size.toByte()))\n            output.write(p)\n            output.flush()\n            val auth = readExactly(input, 2)\n            if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false\n''',
        '''        if (port <= 0) return false\n        var socket: Socket? = null\n        return try {\n            socket = Socket()\n            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), timeoutMs)\n            socket.soTimeout = timeoutMs\n            val input = socket.getInputStream()\n            val output = socket.getOutputStream()\n\n            val usePasswordAuth = user.isNotEmpty() && pass.isNotEmpty()\n            val method: Byte = if (usePasswordAuth) 0x02 else 0x00\n            output.write(byteArrayOf(0x05, 0x01, method))\n            output.flush()\n            val greeting = readExactly(input, 2)\n            if (greeting[0].toInt() != 0x05 || greeting[1] != method) return false\n            if (usePasswordAuth) {\n                val u = user.toByteArray(Charsets.UTF_8)\n                val p = pass.toByteArray(Charsets.UTF_8)\n                if (u.isEmpty() || u.size > 255 || p.isEmpty() || p.size > 255) return false\n                output.write(byteArrayOf(0x01, u.size.toByte()))\n                output.write(u)\n                output.write(byteArrayOf(p.size.toByte()))\n                output.write(p)\n                output.flush()\n                val auth = readExactly(input, 2)\n                if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false\n            }\n''',
        'made SOCKS probe compatible with legacy noauth',
    )

elif variant == 'no-socks-watchdog':
    replace_once(
        SERVICE,
        '''                if (proxyOnly) {\n                    if (!waitForSocks(config, generation)) {\n                        throw IllegalStateException("Local SOCKS5 did not become ready")\n                    }\n                    AppConfigs.SOCKS_READY = true\n''',
        '''                if (proxyOnly) {\n                    val abSocksReady = waitForSocks(config, generation)\n                    if (!abSocksReady) {\n                        Log.w(TAG, "A/B no-socks-watchdog: ignoring SOCKS readiness failure")\n                    }\n                    AppConfigs.SOCKS_READY = true\n''',
        'disabled proxy-only SOCKS readiness fail-close',
    )
    replace_once(
        SERVICE,
        '''        if (!waitForSocks(config, generation)) {\n            throw IllegalStateException("Authenticated SOCKS5 ingress did not become ready")\n        }\n        AppConfigs.SOCKS_READY = true\n''',
        '''        val abSocksReady = waitForSocks(config, generation)\n        if (!abSocksReady) {\n            Log.w(TAG, "A/B no-socks-watchdog: ignoring SOCKS readiness failure")\n        }\n        AppConfigs.SOCKS_READY = true\n''',
        'disabled TUN SOCKS readiness fail-close',
    )

elif variant == 'no-tun2socks-exit-kill':
    replace_once(
        SERVICE,
        '''                if (generation == currentGeneration && runtimeExpected && !stopping) {\n                    Log.e(TAG, "tun2socks exited unexpectedly with code $code")\n                    terminateService(\n                        "tun2socks exited unexpectedly",\n                        preserveConfig = true,\n                    )\n                }\n''',
        '''                if (generation == currentGeneration && runtimeExpected && !stopping) {\n                    Log.e(TAG, "A/B no-tun2socks-exit-kill: tun2socks exited with code $code")\n                }\n''',
        'disabled tun2socks exit auto-terminate',
    )
    replace_once(
        SERVICE,
        '''                if (generation == currentGeneration && runtimeExpected && !stopping) {\n                    Log.e(TAG, "tun2socks monitor failed", e)\n                    terminateService(\n                        "tun2socks monitor failed",\n                        preserveConfig = true,\n                    )\n                }\n''',
        '''                if (generation == currentGeneration && runtimeExpected && !stopping) {\n                    Log.e(TAG, "A/B no-tun2socks-exit-kill: monitor failed", e)\n                }\n''',
        'disabled tun2socks monitor auto-terminate',
    )

elif variant == 'no-dart-readiness-cleanup':
    replace_once(
        DART,
        '''      _setStatus(VpnStatus.connecting, 'Verifying VPN data path…');\n      if (!await _waitForNativeConnected()) {\n        throw StateError('Native TUN/FD/SOCKS readiness was not confirmed');\n      }\n''',
        '''      _setStatus(VpnStatus.connecting, 'A/B: native readiness cleanup disabled…');\n      // Diagnostic variant: do not let Dart tear down a native runtime solely\n      // because its readiness observer returned false. Native fail-close paths\n      // remain unchanged.\n      await Future<void>.delayed(const Duration(milliseconds: 800));\n''',
        'disabled Dart native-readiness cleanup gate',
    )

elif variant == 'no-generation-lifecycle-guard':
    replace_once(
        SERVICE,
        '''            val generation = ++currentGeneration\n            runtimeExpected = false\n            shutdownRuntimeInternal(broadcast = false, keepConfig = true)\n            prepareRuntimeIsolation(config)\n''',
        '''            val generation = ++currentGeneration\n            runtimeExpected = false\n            // Diagnostic variant: skip the pre-start destructive cleanup and\n            // generation-driven teardown path. A fresh install/start has no stale\n            // runtime, so this isolates lifecycle guard interference.\n            prepareRuntimeIsolation(config)\n''',
        'disabled destructive pre-start lifecycle cleanup',
    )
    replace_once(
        SERVICE,
        '''        if (generation != currentGeneration || stopping) {\n            established.close()\n            throw IllegalStateException("VPN startup was superseded")\n        }\n''',
        '''        if (stopping) {\n            established.close()\n            throw IllegalStateException("VPN startup was explicitly stopped")\n        }\n''',
        'disabled generation supersede abort after TUN establish',
    )
    replace_once(
        CORE,
        '''        synchronized(processLock) {\n            if (activeGeneration != generation || xrayProcess?.isAlive != true) return false\n        }\n        if (!AppConfigs.TUN_ESTABLISHED ||\n''',
        '''        synchronized(processLock) {\n            if (xrayProcess?.isAlive != true) return false\n        }\n        if (!AppConfigs.TUN_ESTABLISHED ||\n''',
        'disabled generation equality gate for native CONNECTED',
    )

print(f'A/B variant ready: {variant}')
