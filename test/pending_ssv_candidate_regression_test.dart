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
    // still arrive. The pending nonce therefore remains reusable.
    final earnedFalse = ads.indexOf('if (!earned) {');
    final confirmHelper = ads.indexOf(
      'Future<bool> _confirmMainCandidate',
      earnedFalse,
    );
    expect(earnedFalse, greaterThanOrEqualTo(0));
    expect(confirmHelper, greaterThan(earnedFalse));
    final failedRewardPath = ads.substring(earnedFalse, confirmHelper);
    expect(
      failedRewardPath,
      isNot(contains('clearPendingMainSessionNonceIfMatches')),
    );
  });

  test('rewarded ad execution is single-flight', () {
    final ads = File('lib/logic/ad_manager.dart').readAsStringSync();

    expect(ads, contains('Future<bool>? _showInFlight;'));
    expect(ads, contains('final existing = _showInFlight;'));
    expect(ads, contains('if (existing != null) return existing;'));
    expect(ads, contains('identical(_showInFlight, tracked)'));
  });
}
