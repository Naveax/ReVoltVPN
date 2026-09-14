import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main reward flow reserves exact candidate before any callback or ad', () {
    final candidateSource = File(
      'lib/logic/session_candidate_service.dart',
    ).readAsStringSync();
    final adSource = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(candidateSource, contains("RegExp(r'^[0-9a-f]{32}\$')"));
    expect(candidateSource, contains("'$basePath/session/candidate'"));
    expect(candidateSource, contains("query: null"));
    expect(candidateSource, contains("fragment: null"));
    expect(candidateSource, contains('HivemindService.directPost('));
    expect(candidateSource, contains('X-RevoltVPN-Session-Nonce'));
    expect(candidateSource, contains("jsonEncode(<String, String>{'device_id': deviceId})"));
    expect(candidateSource, contains('response.statusCode != 200'));
    expect(candidateSource, contains("decoded['ok'] == true"));
    expect(candidateSource, isNot(contains('setSessionNonce(')));
    expect(candidateSource, isNot(contains('debugPrint')));

    final nonceIndex = adSource.indexOf('nonce = HivemindService.newNonce();');
    final reserveIndex = adSource.indexOf(
      'SessionCandidateService.register(nonce)',
      nonceIndex,
    );
    final debugCallbackIndex = adSource.indexOf(
      'if (!adsEnabled && kDebugMode)',
      reserveIndex,
    );
    final sdkInitIndex = adSource.indexOf(
      'await ensureSdkInitialized();',
      reserveIndex,
    );

    expect(nonceIndex, greaterThanOrEqualTo(0));
    expect(reserveIndex, greaterThan(nonceIndex));
    expect(debugCallbackIndex, greaterThan(reserveIndex));
    expect(sdkInitIndex, greaterThan(reserveIndex));
    expect(
      adSource.substring(nonceIndex, debugCallbackIndex),
      contains('return false;'),
    );
  });
}
