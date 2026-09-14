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
    expect(candidateSource, contains('getSessionStopEpoch()'));
    expect(candidateSource, contains('_registrationStillCurrent(stopEpoch)'));
    expect(candidateSource, contains('setSessionStopPending()'));
    expect(candidateSource, contains('clearPendingSessionCandidate()'));
    expect(candidateSource, contains('_cancelExact(deviceId, candidate)'));
    expect(candidateSource, isNot(contains('setSessionNonce(')));
    expect(candidateSource, isNot(contains('debugPrint')));

    expect(
      cryptoSource,
      contains("_pendingSessionCandidatePref = 'pending_session_candidate_nonce'"),
    );
    expect(
      cryptoSource,
      contains("_sessionStopEpochPref = 'session_stop_epoch'"),
    );
    expect(cryptoSource, contains('setPendingSessionCandidate(String nonce)'));
    expect(cryptoSource, contains('getPendingSessionCandidate()'));
    expect(cryptoSource, contains('getSessionStopEpoch()'));
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
    expect(
      cryptoSource,
      contains("await _storage.write(key: _sessionStopPendingPref, value: '1');"),
    );
    expect(
      cryptoSource,
      contains('value: (current + 1).toString(),'),
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
    final firstCurrentCheck = adSource.indexOf(
      'SessionCandidateService.isCurrent(nonce)',
      supportStart,
    );
    final debugCallbackIndex = adSource.indexOf(
      '// Debug-only compatibility callback.',
      firstCurrentCheck,
    );
    final sdkInitIndex = adSource.indexOf(
      'await ensureSdkInitialized();',
      debugCallbackIndex,
    );
    final ssvOptionsIndex = adSource.indexOf(
      'final ssvOptions = ServerSideVerificationOptions(',
      sdkInitIndex,
    );
    final currentBeforeSsv = adSource.lastIndexOf(
      'SessionCandidateService.isCurrent(nonce)',
      ssvOptionsIndex,
    );
    final confirmIndex = adSource.lastIndexOf(
      'HivemindService.confirmAndSetSessionNonce(nonce)',
    );
    final currentBeforeConfirm = adSource.lastIndexOf(
      'SessionCandidateService.isCurrent(nonce)',
      confirmIndex,
    );

    expect(mainStart, greaterThanOrEqualTo(0));
    expect(recoveryIndex, greaterThan(mainStart));
    expect(retryStopIndex, greaterThan(recoveryIndex));
    expect(nonceIndex, greaterThan(retryStopIndex));
    expect(reserveIndex, greaterThan(nonceIndex));
    expect(supportStart, greaterThan(reserveIndex));
    expect(firstCurrentCheck, greaterThan(supportStart));
    expect(debugCallbackIndex, greaterThan(firstCurrentCheck));
    expect(sdkInitIndex, greaterThan(debugCallbackIndex));
    expect(currentBeforeSsv, greaterThan(sdkInitIndex));
    expect(ssvOptionsIndex, greaterThan(currentBeforeSsv));
    expect(currentBeforeConfirm, greaterThan(ssvOptionsIndex));
    expect(confirmIndex, greaterThan(currentBeforeConfirm));
    expect(
      adSource.substring(nonceIndex, supportStart),
      contains('return false;'),
    );
    expect(
      adSource.substring(supportStart, debugCallbackIndex),
      isNot(contains('SessionCandidateService.register')),
    );
    expect(adSource, contains('cancelMainCandidate()'));
    expect(adSource, contains('if (!confirmed) await cancelMainCandidate();'));
  });
}
