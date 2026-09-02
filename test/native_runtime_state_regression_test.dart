import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native runtime is generation-scoped, readiness-gated and deadline-bound', () {
    const root = 'local_packages/flutter_vless_android-1.1.5/android/src/main/kotlin/com/github/tfox/flutter_vless';
    final plugin = File('$root/FlutterVlessPlugin.kt').readAsStringSync();
    final config = File('$root/xray/dto/XrayConfig.kt').readAsStringSync();
    final service = File('$root/xray/service/XrayVPNService.kt').readAsStringSync();
    final core = File('$root/xray/core/XrayCoreManager.kt').readAsStringSync();
    final timer = File('lib/logic/session_timer.dart').readAsStringSync();
    final vpn = File('lib/logic/vpn_connection.dart').readAsStringSync();

    expect(config, contains('var RUNTIME_TOKEN: String = ""'));
    expect(plugin, contains('expectedRuntimeToken'));
    expect(plugin, contains('runtimeToken != currentToken'));
    expect(plugin, contains('runtimeReady'));
    expect(plugin, contains('STOP_TIMEOUT'));
    expect(plugin, contains('setSessionDeadline'));
    expect(service, contains('BOOTSTRAP_SESSION_SECONDS = 120L'));
    expect(service, contains('UPDATE_SESSION_DEADLINE'));
    expect(service, contains('SystemClock.elapsedRealtime()'));
    expect(service, contains('markRuntimeReady(this, config)'));
    expect(core, contains('AppConfigs.RUNTIME_READY = false'));
    expect(core, contains('fun markRuntimeReady'));
    expect(timer, contains('setNativeSessionDeadline(_remainingAtLastSync)'));
    expect(vpn, contains("MethodChannel('flutter_vless')"));
  });
}
