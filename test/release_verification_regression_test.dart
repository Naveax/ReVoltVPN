import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

void main() {
  test('release verification stays fail-closed and reproducible', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final workflow = File('.github/workflows/android-ci.yml').readAsStringSync();
    final lockfile = File('pubspec.lock').readAsStringSync();
    final wrapper =
        File('android/gradle/wrapper/gradle-wrapper.properties').readAsStringSync();
    final verification =
        File('android/gradle/verification-metadata.xml').readAsStringSync();
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

    expect(workflow, contains("flutter-version: '3.47.2'"));
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
    final session = await SecureSocksSession.create(jsonEncode({
      'inbounds': <Object?>[],
      'outbounds': <Object?>[],
    }));
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
}
