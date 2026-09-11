import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main SSV candidates survive delayed callbacks and process loss', () {
    final crypto = File('lib/logic/crypto_service.dart').readAsStringSync();
    final ads = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(crypto, contains("'pending_main_session_nonce'"));
    expect(crypto, contains('setPendingMainSessionNonce'));
    expect(crypto, contains('getPendingMainSessionNonce'));
    expect(crypto, contains('clearPendingMainSessionNonceIfMatches'));
    expect(crypto, contains('_requireSessionNonce(nonce)'));

    // A replacement device UUID must never inherit authorization state that
    // was bound to the previous device identity.
    expect(crypto, contains('await _clearDeviceBoundSessionState();'));
    final deviceReset = crypto.indexOf(
      'static Future<void> _clearDeviceBoundSessionState()',
    );
    expect(deviceReset, greaterThanOrEqualTo(0));
    final nonceValidation = crypto.indexOf(
      'static void _requireSessionNonce',
      deviceReset,
    );
    expect(nonceValidation, greaterThan(deviceReset));
    final resetSource = crypto.substring(deviceReset, nonceValidation);
    expect(resetSource, contains('_sessionNoncePref'));
    expect(resetSource, contains('_pendingMainSessionNoncePref'));
    expect(resetSource, contains('_sessionStopPendingPref'));

    // A pending candidate must be recovered/reused before another random nonce
    // can be minted, otherwise a late Google callback can orphan a live server
    // generation behind a possession token the client forgot.
    final pendingRead = ads.indexOf('getPendingMainSessionNonce()');
    final newNonce = ads.indexOf('HivemindService.newNonce()', pendingRead);
    expect(pendingRead, greaterThanOrEqualTo(0));
    expect(newNonce, greaterThan(pendingRead));
    expect(ads, contains('if (await _confirmMainCandidate(pending)) return true;'));
    expect(ads, contains('nonce = pending;'));

    // The candidate must be durable before its value is handed to Google SSV.
    final persist = ads.indexOf('setPendingMainSessionNonce(nonce)');
    final ssv = ads.indexOf('ServerSideVerificationOptions(', persist);
    expect(persist, greaterThanOrEqualTo(0));
    expect(ssv, greaterThan(persist));

    // Cleanup is compare-and-delete and happens only after server confirmation.
    expect(
      ads,
      contains(
        'final confirmed = await HivemindService.confirmAndSetSessionNonce(nonce);',
      ),
    );
    expect(ads, contains('if (confirmed) {'));
    expect(ads, contains('clearPendingMainSessionNonceIfMatches(nonce)'));

    // Losing one local ad attempt is not proof that an older SSV callback cannot
    // still arrive. The pending nonce therefore remains reusable unless an
    // explicit disconnect has installed the durable stop barrier.
    final earnedFalse = ads.indexOf('if (!earned) {');
    final stageHelper = ads.indexOf(
      'Future<bool> _stageMainCandidate',
      earnedFalse,
    );
    expect(earnedFalse, greaterThanOrEqualTo(0));
    expect(stageHelper, greaterThan(earnedFalse));
    final failedRewardPath = ads.substring(earnedFalse, stageHelper);
    expect(
      failedRewardPath,
      isNot(contains('clearPendingMainSessionNonceIfMatches')),
    );
  });

  test('explicit disconnect cancels pending SSV staging fail-closed', () {
    final crypto = File('lib/logic/crypto_service.dart').readAsStringSync();
    final ads = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(crypto, contains('clearPendingMainSessionNonce()'));

    final stopStart = crypto.indexOf(
      'static Future<void> setSessionStopPending()',
    );
    final stopRead = crypto.indexOf(
      'static Future<bool> isSessionStopPending()',
      stopStart,
    );
    expect(stopStart, greaterThanOrEqualTo(0));
    expect(stopRead, greaterThan(stopStart));
    final stopSource = crypto.substring(stopStart, stopRead);
    expect(stopSource, contains("_sessionStopPendingPref, value: '1'"));
    expect(stopSource, contains('clearPendingMainSessionNonce()'));

    final clearStop = crypto.indexOf(
      'static Future<void> clearSessionStopPending()',
      stopRead,
    );
    expect(clearStop, greaterThan(stopRead));
    final stopReadSource = crypto.substring(stopRead, clearStop);
    expect(stopReadSource, contains('if (pending)'));
    expect(stopReadSource, contains('clearPendingMainSessionNonce()'));

    final stageStart = ads.indexOf('Future<bool> _stageMainCandidate');
    final confirmStart = ads.indexOf(
      'Future<bool> _confirmMainCandidate',
      stageStart,
    );
    expect(stageStart, greaterThanOrEqualTo(0));
    expect(confirmStart, greaterThan(stageStart));
    final stageSource = ads.substring(stageStart, confirmStart);

    // The stop marker is checked on both sides of secure-storage persistence.
    expect(
      RegExp(r'isSessionStopPending\(\)').allMatches(stageSource).length,
      greaterThanOrEqualTo(2),
    );
    expect(stageSource, contains('setPendingMainSessionNonce(nonce)'));
    expect(stageSource, contains('clearPendingMainSessionNonceIfMatches(nonce)'));

    // Both debug and production SSV paths must use the guarded staging helper.
    expect(
      RegExp(r'_stageMainCandidate\(nonce\)').allMatches(ads).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('rewarded ad execution is single-flight and intent-bound', () {
    final ads = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(ads, contains('Future<bool>? _showInFlight;'));
    expect(ads, contains('String? _showInFlightType;'));
    expect(ads, contains('final existing = _showInFlight;'));
    expect(ads, contains('_showInFlightType == adType'));
    expect(ads, contains(': Future<bool>.value(false);'));
    expect(ads, contains('identical(_showInFlight, tracked)'));
    expect(ads, contains('_showInFlightType = null;'));
    expect(ads, contains('_showInFlightType = adType;'));
  });
}
