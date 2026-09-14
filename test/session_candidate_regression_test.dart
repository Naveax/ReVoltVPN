import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main reward flow reserves and revokes exact pre-activation capability', () {
    final candidateSource = File(
      'lib/logic/session_candidate_service.dart',
    ).readAsStringSync();
    final cryptoSource = File(
      'lib/logic/crypto_service.dart',
    ).readAsStringSync();
    final adSource = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(candidateSource, contains("RegExp(r'^[0-9a-f]{32}\$')"));
    expect(candidateSource, contains("_publicUrl('session/candidate')"));
    expect(candidateSource, contains("_publicUrl('session/stop')"));
    expect(candidateSource, contains('query: null'));
    expect(candidateSource, contains('fragment: null'));
    expect(candidateSource, contains('HivemindService.directPost('));
    expect(candidateSource, contains('X-RevoltVPN-Session-Nonce'));
    expect(
      candidateSource,
      contains("jsonEncode(<String, String>{'device_id': deviceId})"),
    );
    expect(candidateSource, contains('response.statusCode != 200'));
    expect(candidateSource, contains("decoded['ok'] != true"));
    expect(candidateSource, contains('setPendingSessionCandidate(nonce)'));
    expect(candidateSource, contains('getPendingSessionCandidate()'));
    expect(candidateSource, contains('setSessionStopPending()'));
    expect(candidateSource, contains('stopSession(markPending: false)'));
    expect(candidateSource, isNot(contains('setSessionNonce(')));
    expect(candidateSource, isNot(contains('debugPrint')));

    expect(
      cryptoSource,
      contains("_pendingSessionCandidatePref = 'pending_session_candidate_nonce'"),
    );
    expect(cryptoSource, contains('setPendingSessionCandidate(String nonce)'));
    expect(cryptoSource, contains('getPendingSessionCandidate()'));
    expect(
      cryptoSource,
      contains('if (await isSessionStopPending()) {'),
    );
    expect(
      cryptoSource,
      contains('return _readCanonicalNonce(_pendingSessionCandidatePref);'),
    );
    expect(
      cryptoSource,
      contains('await _storage.delete(key: _pendingSessionCandidatePref);'),
    );

    final mainStart = adSource.indexOf("if (adType == 'main') {");
    final recoveryIndex = adSource.indexOf(
      'SessionCandidateService.recoverOrphanedReservation()',
      mainStart,
    );
    final retryStopIndex = adSource.indexOf(
      'HivemindService.retryPendingSessionStop()',
      recoveryIndex,
    );
    final nonceIndex = adSource.indexOf(
      'nonce = HivemindService.newNonce();',
      retryStopIndex,
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
    expect(recoveryIndex, greaterThan(mainStart));
    expect(retryStopIndex, greaterThan(recoveryIndex));
    expect(nonceIndex, greaterThan(retryStopIndex));
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
    expect(adSource, contains('cancelMainCandidate()'));
    expect(adSource, contains('CryptoService.isSessionStopPending()'));
    expect(adSource, contains('if (!confirmed) await cancelMainCandidate();'));
  });
}
