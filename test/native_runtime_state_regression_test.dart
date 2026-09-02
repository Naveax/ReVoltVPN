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
    final main = File('lib/main.dart').readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();
    final support = File('lib/components/support_button.dart').readAsStringSync();
    final connectionSettings =
        File('lib/logic/connection_settings.dart').readAsStringSync();

    expect(config, contains('var RUNTIME_TOKEN: String = ""'));
    expect(plugin, contains('expectedRuntimeToken'));
    expect(plugin, contains('runtimeToken != currentToken'));
    expect(plugin, contains('runtimeReady'));
    expect(plugin, contains('STOP_TIMEOUT'));
    expect(plugin, contains('setSessionDeadline'));
    expect(plugin, contains('result.error("NO_ACTIVITY"'));
    expect(plugin, isNot(contains('activity!!')));

    expect(service, contains('BOOTSTRAP_SESSION_SECONDS = 120L'));
    expect(service, contains('UPDATE_SESSION_DEADLINE'));
    expect(service, contains('SystemClock.elapsedRealtime()'));
    expect(service, contains('AlarmManager.RTC_WAKEUP'));
    expect(service, contains('setExactAndAllowWhileIdle'));
    expect(service, contains('setAndAllowWhileIdle'));
    expect(service, contains('PREF_EXPIRES_AT_MS'));
    expect(service, contains('PREF_RUNTIME_TOKEN'));
    expect(service, contains('markRuntimeReady(this, config)'));
    expect(service, contains('Per-session VLESS/SOCKS credentials remain memory-only'));
    expect(service, contains('if (currentConfig == null) stopSelf()'));
    expect(service, isNot(contains('sessionDeadlineEpochMs')));
    expect(service, isNot(contains('active_session.bin')));
    expect(service, isNot(contains('ObjectOutputStream')));

    expect(core, contains('AppConfigs.RUNTIME_READY = false'));
    expect(core, contains('fun markRuntimeReady'));
    expect(timer, contains('setNativeSessionDeadline(_remainingAtLastSync)'));
    expect(timer, contains('Future.microtask(_onVpnConnectionChanged)'));
    expect(timer, contains('Connected with a stopped clock - resuming.'));
    expect(timer, contains('Completer<void>? _syncCompletion'));
    expect(timer, contains('await active.future;'));
    expect(main, contains('ChangeNotifierProxyProvider<VpnConnection, SessionTimer>('));
    expect(main, contains('lazy: false'));
    expect(support, contains('await timer.syncNow();'));
    expect(vpn, contains("MethodChannel('flutter_vless')"));

    // UI notification refreshes must never mint an unscoped STOP action.
    // Reuse the token-scoped PendingIntent owned by the live native service.
    expect(mainActivity, contains('manager.activeNotifications'));
    expect(mainActivity, contains('serviceStopAction'));
    expect(mainActivity, isNot(contains('V2RAY_SERVICE_COMMANDS.STOP_SERVICE')));
    expect(mainActivity, isNot(contains('XrayVPNService::class.java')));

    expect(
      connectionSettings,
      contains('storedMode == ConnectionMode.proxy.name'),
    );
    expect(connectionSettings, isNot(contains("storedMode == 'ass'")));
  });
}
