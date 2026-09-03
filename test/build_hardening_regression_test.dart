import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production release config is fail-closed and hash pinned', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final workflow =
        File('.github/workflows/android-ci.yml').readAsStringSync();

    expect(gradle, contains('REVOLT_APP_CONFIG_SHA256'));
    expect(gradle, contains('MessageDigest.getInstance("SHA-256")'));
    expect(gradle, contains('verifyReleaseAppConfig'));
    expect(gradle, contains('GITHUB_ACTIONS'));
    expect(gradle, contains('REVOLT_CI_RELEASE_SMOKE'));
    expect(gradle, contains('Production app config SHA-256 mismatch'));
    expect(gradle, contains('YOUR_DOMAIN'));
    expect(workflow, contains(':app:verifyReleaseAppConfig'));
    expect(
      workflow,
      contains('REVOLT_APP_CONFIG_SHA256 is required for production release builds'),
    );
  });

  test('Android lint is a required CI gate', () {
    final workflow =
        File('.github/workflows/android-ci.yml').readAsStringSync();

    expect(workflow, contains('name: Android lint'));
    expect(workflow, contains('./gradlew :app:lintDebug --no-daemon'));
  });

  test('R8 cleanup preserves AdMob rules and removes redundant Flutter subsets', () {
    final proguard = File('android/app/proguard-rules.pro').readAsStringSync();

    expect(proguard, contains('-keep class io.flutter.** { *; }'));
    expect(proguard, isNot(contains('-keep class io.flutter.embedding.** { *; }')));
    expect(proguard, isNot(contains('-keep class io.flutter.plugin.** { *; }')));
    expect(proguard, contains('-keep class com.google.android.gms.ads.** { *; }'));
    expect(proguard, contains('-dontwarn com.google.android.gms.ads.**'));
  });
}
