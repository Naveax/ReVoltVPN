import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main reward flow reserves exact candidate before any callback or ad', () {
    final candidateSource = File(
      'lib/logic/session_candidate_service.dart',
    ).readAsStringSync();
    final adSource = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(candidateSource, contains("RegExp(r'^[0-9a-f]{32}\$')"));
    expect(candidateSource, contains(r"'$basePath/session/candidate'"));
    expect(candidateSource, contains('query: null'));
    expect(candidateSource, contains('fragment: null'));
    expect(candidateSource, contains('HivemindService.directPost('));
    expect(candidateSource, contains('X-RevoltVPN-Session-Nonce'));
    expect(
      candidateSource,
      contains("jsonEncode(<String, String>{'device_id': deviceId})"),
    );
    expect(candidateSource, contains('response.statusCode != 200'));
    expect(candidateSource, contains("decoded['ok'] == true"));
    expect(candidateSource, isNot(contains('setSessionNonce(')));
    expect(candidateSource, isNot(contains('debugPrint')));

    final mainStart = adSource.indexOf("if (adType == 'main') {");
    final nonceIndex = adSource.indexOf(
      'nonce = HivemindService.newNonce();',
      mainStart,
    );
    final reserveIndex = adSource.indexOf(
      'SessionCandidateService.register(nonce)',
      nonceIndex,
    );
    final supportStart = adSource.indexOf('} else {', reserveIndex);
    final debugCallbackIndex = adSource.indexOf(
      '// Debug-only compatibility callback.',
      supportStart,
    );
    final sdkInitIndex = adSource.indexOf(
      'await ensureSdkInitialized();',
      debugCallbackIndex,
    );

    expect(mainStart, greaterThanOrEqualTo(0));
    expect(nonceIndex, greaterThan(mainStart));
    expect(reserveIndex, greaterThan(nonceIndex));
    expect(supportStart, greaterThan(reserveIndex));
    expect(debugCallbackIndex, greaterThan(supportStart));
    expect(sdkInitIndex, greaterThan(debugCallbackIndex));
    expect(
      adSource.substring(nonceIndex, supportStart),
      contains('return false;'),
    );
    expect(
      adSource.substring(supportStart, debugCallbackIndex),
      isNot(contains('SessionCandidateService.register')),
    );
  });
}
