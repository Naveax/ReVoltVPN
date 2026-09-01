import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android background/runtime controls used by the VPN UI.
abstract final class PowerSettings {
  PowerSettings._();

  static const MethodChannel _powerChannel = MethodChannel(
    'com.revoltvpn.app/power',
  );
  static const MethodChannel _vlessChannel = MethodChannel('flutter_vless');

  /// Whether the user has exempted ReVolt from Doze/App Standby.
  ///
  /// This is optional extra resilience. The foreground VpnService is still the
  /// primary mechanism that keeps an active tunnel alive.
  static Future<bool> isBatteryOptimisationDisabled() async {
    if (kIsWeb) return true;
    try {
      return await _powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's battery-optimisation exemption UI.
  static Future<bool> requestDisableBatteryOptimisation() async {
    if (kIsWeb) return true;
    try {
      return await _powerChannel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Returns both the OS-level VPN shape and the service-process health probe.
  /// A process plus a VPN key is not sufficient: Xray, the authenticated SOCKS
  /// outbound, tun2socks and the TUN FD handoff must all be working.
  static Future<VpnRuntimeState> runtimeState() async {
    if (kIsWeb) return const VpnRuntimeState.empty();

    Map<String, dynamic>? osState;
    Map<String, dynamic>? health;
    try {
      osState = await _powerChannel.invokeMapMethod<String, dynamic>(
        'isVpnRuntimeAlive',
      );
    } catch (_) {}
    try {
      health = await _vlessChannel.invokeMapMethod<String, dynamic>(
        'getRuntimeHealth',
      );
    } catch (_) {}

    return VpnRuntimeState(
      processAlive: osState?['processAlive'] == true,
      vpnTransport: osState?['vpnTransport'] == true,
      healthy: health?['healthy'] == true,
      stale: health?['stale'] != false,
      proxyOnly: health?['proxyOnly'] == true,
      xrayAlive: health?['xrayAlive'] == true,
      tun2socksAlive: health?['tun2socksAlive'] == true,
      fdReady: health?['fdReady'] == true,
      outboundReady: health?['outboundReady'] == true,
    );
  }
}

@immutable
class VpnRuntimeState {
  final bool processAlive;
  final bool vpnTransport;
  final bool healthy;
  final bool stale;
  final bool proxyOnly;
  final bool xrayAlive;
  final bool tun2socksAlive;
  final bool fdReady;
  final bool outboundReady;

  const VpnRuntimeState({
    required this.processAlive,
    required this.vpnTransport,
    required this.healthy,
    required this.stale,
    required this.proxyOnly,
    required this.xrayAlive,
    required this.tun2socksAlive,
    required this.fdReady,
    required this.outboundReady,
  });

  const VpnRuntimeState.empty()
      : processAlive = false,
        vpnTransport = false,
        healthy = false,
        stale = true,
        proxyOnly = false,
        xrayAlive = false,
        tun2socksAlive = false,
        fdReady = false,
        outboundReady = false;

  bool aliveFor({required bool tunMode}) {
    final modeMatches = tunMode ? !proxyOnly : proxyOnly;
    final componentsHealthy = xrayAlive &&
        outboundReady &&
        (proxyOnly || (tun2socksAlive && fdReady));
    return processAlive &&
        !stale &&
        healthy &&
        componentsHealthy &&
        modeMatches &&
        (!tunMode || vpnTransport);
  }
}
