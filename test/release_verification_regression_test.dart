import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

void main() {
  test('release verification stays fail-closed and reproducible', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final vendoredGradle = File(
      'local_packages/flutter_vless_android-1.1.5/android/build.gradle',
    ).readAsStringSync();
    final workflow = File('.github/workflows/android-ci.yml').readAsStringSync();
    final lockfile = File('pubspec.lock').readAsStringSync();
    final wrapper = File(
      'android/gradle/wrapper/gradle-wrapper.properties',
    ).readAsStringSync();
    final verification = File(
      'android/gradle/verification-metadata.xml',
    ).readAsStringSync();
    final proguard = File('android/app/proguard-rules.pro').readAsStringSync();

    expect(
      wrapper,
      contains(
        'distributionSha256Sum='
        'efe9a3d147d948d7528a9887fa35abcf24ca1a43ad06439996490f77569b02d1',
      ),
    );
    expect(wrapper, contains('validateDistributionUrl=true'));

    expect(verification, contains('<verify-metadata>true</verify-metadata>'));
    expect(verification, contains('<verify-signatures>false</verify-signatures>'));
    expect(verification, contains('<sha256 value='));
    expect(
      verification,
      contains('a804b261645ef8c13eb3d5c44a5c2fb0340c5539'),
    );

    expect(gradle, contains('REVOLT_APP_CONFIG_SHA256'));
    expect(gradle, contains('verifyReleaseAppConfig'));
    expect(gradle, contains('preReleaseBuild'));
    expect(gradle, contains('isMinifyEnabled = true'));
    expect(gradle, contains('isShrinkResources = true'));
    expect(gradle, contains('REVOLT_CI_RELEASE_SMOKE'));
    expect(gradle, contains('signingConfigs.getByName("release")'));

    // The protected Xray artifact is downloaded and SHA-256 verified by the
    // vendored runtime project, but packaged only by the final app. This avoids
    // the unsupported local-AAR-inside-library-AAR graph that AGP rejects.
    expect(
      vendoredGradle,
      contains(
        '54785c3c5437473d8f9c8071a6138ae781ed2038e57beb47b6a46de3545c3ad8',
      ),
    );
    expect(vendoredGradle, contains('prepareProtectedXrayRuntime'));
    expect(
      vendoredGradle,
      isNot(contains('implementation files(protectedRuntimeAar)')),
    );
    expect(gradle, contains('implementation(protectedXrayRuntimeFiles)'));
    expect(
      gradle,
      contains(':flutter_vless_android:prepareProtectedXrayRuntime'),
    );

    expect(workflow, contains("flutter-version: '3.47.2'"));
    expect(workflow, contains('Verify Flutter SDK identity'));
    expect(
      workflow,
      contains('d3b14c876900e553bc736ca19295fc09e3853e8e'),
    );
    expect(workflow, contains('flutter_framework_sha='));
    expect(workflow, contains('flutter pub get --enforce-lockfile'));
    expect(workflow, contains('for attempt in 1 2 3'));
    expect(
      workflow,
      contains('Locked dependency resolution failed after 3 attempts.'),
    );
    expect(workflow, contains('Verify Gradle supply chain'));
    expect(workflow, contains('Verify dependency lock is committed'));
    expect(workflow, contains('Verify production release config fails closed'));
    expect(workflow, contains('Cold APK build'));
    expect(workflow, contains('Warm APK build'));
    expect(workflow, contains('Release R8 smoke build'));
    expect(workflow, contains('Verify tracked build inputs stayed immutable'));
    expect(workflow, contains('REVOLT_CI_RELEASE_SMOKE'));
    expect(
      workflow,
      contains('actions/checkout@11d5960a326750d5838078e36cf38b85af677262'),
    );
    expect(
      workflow,
      contains('actions/setup-java@b6effb05e454b25005698d916606bdc6ffcbf961'),
    );
    expect(lockfile, contains('dart: ">=3.11.0-0 <4.0.0"'));

    expect(proguard, contains('-keep class io.flutter.** { *; }'));
    expect(proguard, contains('-keep class xray.** { *; }'));
  });

  test('runtime keeps authenticated SOCKS on the IPv4 loopback', () async {
    final session = await SecureSocksSession.create(
      jsonEncode({
        'inbounds': <Object?>[],
        'outbounds': <Object?>[],
      }),
    );
    final config = jsonDecode(session.configJson) as Map<String, dynamic>;
    final inbounds = config['inbounds'] as List<dynamic>;
    final inbound = inbounds.single as Map<String, dynamic>;
    final settings = inbound['settings'] as Map<String, dynamic>;
    final users = settings['users'] as List<dynamic>;
    final account = users.single as Map<String, dynamic>;

    expect(inbound['tag'], SecureSocksSession.inboundTag);
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['port'], session.port);
    expect(settings['auth'], 'password');
    expect(account['user'], session.username);
    expect(account['pass'], session.password);
    expect(session.username, isNotEmpty);
    expect(session.password, isNotEmpty);
  });

  test('session possession nonces are canonical 128-bit values', () {
    final nonces = List<String>.generate(
      128,
      (_) => HivemindService.newNonce(),
    );
    final pattern = RegExp(r'^[0-9a-f]{32}$');

    for (final nonce in nonces) {
      expect(nonce, matches(pattern));
    }
    expect(nonces.toSet(), hasLength(nonces.length));
  });

  test(
    'control-plane source keeps bearer credentials bounded and stop-serialized',
    () {
      final source = File(
        'lib/logic/hivemind_service.dart',
      ).readAsStringSync();
      final vpnSource = File(
        'lib/logic/vpn_connection.dart',
      ).readAsStringSync();

      expect(source, contains('X-RevoltVPN-Session-Nonce'));
      expect(source, contains('followRedirects = false'));
      expect(source, contains('_maxControlResponseBytes = 256 * 1024'));
      expect(source, contains("base.scheme != 'https'"));
      expect(source, contains('uri.origin != base.origin'));
      expect(source, contains("_publicUrl('/session/stop')"));
      expect(source, contains("_publicUrl('/v2/health')"));
      expect(source, isNot(contains("_publicUrl('/health')")));
      expect(source, contains('CryptoService.setSessionStopPending()'));
      expect(source, contains('CryptoService.isSessionStopPending()'));

      // An explicit disconnect advances the synchronous credential epoch;
      // stop then waits for a server-confirmed nonce write before revoking it.
      expect(source, contains('_sessionMutationEpoch++'));
      expect(source, contains('_sessionStopInProgress = true'));
      expect(source, contains('_confirmationInFlight'));
      expect(source, contains('await confirmation'));
      expect(source, contains('mutationEpoch != _sessionMutationEpoch'));
      expect(vpnSource, contains('HivemindService.beginSessionStop()'));

      final stopIntent = vpnSource.indexOf('HivemindService.beginSessionStop()');
      final localStop = vpnSource.indexOf('await _vless.stopVless()', stopIntent);
      expect(stopIntent, greaterThanOrEqualTo(0));
      expect(localStop, greaterThan(stopIntent));
    },
  );

  test('passive session status cannot erase durable revocation state', () {
    final source = File('lib/logic/hivemind_service.dart').readAsStringSync();

    expect(source, contains('static String? _invalidatedSessionNonce;'));
    expect(source, contains('persisted == _invalidatedSessionNonce'));
    expect(source, contains('_sessionMutationIsCurrent'));
    expect(source, contains('_getSessionNonceForStop'));

    final probeStart = source.indexOf(
      'static Future<SessionProbeResult> probeCurrentSession()',
    );
    final confirmStart = source.indexOf(
      'static Future<bool> confirmAndSetSessionNonce',
      probeStart,
    );
    expect(probeStart, greaterThanOrEqualTo(0));
    expect(confirmStart, greaterThan(probeStart));
    final probeSource = source.substring(probeStart, confirmStart);
    expect(probeSource, contains('_invalidateObservedSessionNonce'));
    expect(probeSource, isNot(contains('clearSessionNonce()')));

    final stopStart = source.indexOf(
      'static Future<SessionStopResult> _stopSessionInner',
    );
    final retryStart = source.indexOf(
      'static Future<bool> retryPendingSessionStop',
      stopStart,
    );
    expect(stopStart, greaterThanOrEqualTo(0));
    expect(retryStart, greaterThan(stopStart));
    final stopSource = source.substring(stopStart, retryStart);
    expect(stopSource, contains('await _getSessionNonceForStop()'));

    final fetchStart = source.indexOf(
      'static Future<_HivemindSessionConfig?> _fetchActiveSession',
    );
    final cancelStart = source.indexOf(
      'static void _throwIfCancelled',
      fetchStart,
    );
    expect(fetchStart, greaterThanOrEqualTo(0));
    expect(cancelStart, greaterThan(fetchStart));
    final fetchSource = source.substring(fetchStart, cancelStart);
    expect(fetchSource, contains('_invalidateObservedSessionNonce'));
    expect(fetchSource, isNot(contains('clearSessionNonce()')));
  });

  test('protected Xray TUN requires the authenticated descriptor broker', () {
    const base =
        'local_packages/flutter_vless_android-1.1.5/android/src/main/kotlin/'
        'com/github/tfox/flutter_vless/xray';
    final service = File('$base/service/XrayVPNService.kt').readAsStringSync();
    final protector =
        File('$base/service/XraySocketProtector.kt').readAsStringSync();
    final physicalDns =
        File('$base/service/XrayPhysicalDns.kt').readAsStringSync();
    final core = File('$base/core/XrayCoreManager.kt').readAsStringSync();

    expect(service, contains('XraySocketProtector(this)'));
    expect(service, isNot(contains('builder.addDisallowedApplication(packageName)')));
    expect(service, contains('replaceSocketProtector(required = !currentProxyOnly)'));
    expect(core, contains('FLUTTER_VLESS_PROTECT_SOCKET'));
    expect(core, contains('protector.awaitVerified()'));
    expect(core, contains('requireProtectedSocketSupport(configJson)'));
    expect(protector, contains("'H'.code, 'P'.code"));
    expect(protector, contains("'D'.code"));
    expect(protector, contains('socket.peerCredentials.uid != Process.myUid()'));
    expect(protector, contains('XrayPhysicalDns.query(network, query)'));
    expect(physicalDns, contains('DnsResolver.getInstance().rawQuery'));
    expect(physicalDns, contains('network.getAllByName(host)'));
  });

  test('native VPN service resolves the app notification icon itself', () {
    final service = File(
      'local_packages/flutter_vless_android-1.1.5/android/src/main/kotlin/'
      'com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt',
    ).readAsStringSync();
    final icon = File(
      'android/app/src/main/res/drawable/notification_status_icon.xml',
    );

    expect(icon.existsSync(), isTrue);
    expect(
      service,
      contains(
        'resources.getIdentifier(\n'
        '            "notification_status_icon",',
      ),
    );
    expect(service, contains('.setSmallIcon(icon)'));
    expect(service, contains('android.R.drawable.ic_dialog_info'));
  });
}
