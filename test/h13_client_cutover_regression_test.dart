import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('H13 private authorization never becomes AdMob correlation', () {
    final ads = File('lib/logic/ad_manager.dart').readAsStringSync();
    final activation = File(
      'lib/logic/session_activation_service.dart',
    ).readAsStringSync();
    final config = File(
      'lib/logic/app_config.example.dart',
    ).readAsStringSync();

    expect(
      config,
      contains('static const bool h13ActivationEnabled = false;'),
    );
    expect(ads, contains('if (AppConfig.h13ActivationEnabled)'));
    expect(
      ads,
      contains('final prepared = await SessionActivationService.prepare();'),
    );
    expect(ads, contains('nonce = prepared.activationId;'));
    expect(
      ads,
      contains('SessionActivationService.confirmAndPromote(prepared)'),
    );

    final productionGate = ads.indexOf('if (AppConfig.h13ActivationEnabled)');
    final activationAssignment = ads.indexOf(
      'nonce = prepared.activationId;',
      productionGate,
    );
    final ssv = ads.indexOf(
      'final ssvOptions = ServerSideVerificationOptions(',
    );
    final customNonce = ads.indexOf("'nonce': nonce", ssv);
    expect(productionGate, greaterThanOrEqualTo(0));
    expect(activationAssignment, greaterThan(productionGate));
    expect(ssv, greaterThan(activationAssignment));
    expect(customNonce, greaterThan(ssv));

    final ssvEnd = ads.indexOf('final rewardCompleter', ssv);
    final ssvBlock = ads.substring(ssv, ssvEnd);
    expect(ssvBlock, isNot(contains('sessionSecret')));
    expect(ssvBlock, isNot(contains("'session_secret'")));

    final debugStart = ads.indexOf('if (!adsEnabled && kDebugMode)');
    final debugCallback = ads.indexOf('signature=test', debugStart);
    expect(debugStart, greaterThanOrEqualTo(0));
    expect(debugCallback, greaterThan(debugStart));
    expect(productionGate, greaterThan(debugCallback));

    expect(activation, contains("'h13_pending_session_secret'"));
    expect(activation, contains("'h13_pending_activation_id'"));
    expect(activation, contains("RegExp(r'^[0-9a-f]{32}\$')"));
    expect(activation, contains("'/session/activation-intents'"));
    expect(activation, contains("'/session/status?device_id=\$deviceId'"));
    expect(activation, contains("'X-RevoltVPN-Session-Nonce'"));
    expect(activation, contains('expiresInSeconds != 300'));
  });

  test('H13 ownership transitions remain fail closed across restart races', () {
    final source = File(
      'lib/logic/session_activation_service.dart',
    ).readAsStringSync();

    final prepare = source.indexOf(
      'static Future<SessionActivationIntent?> prepare()',
    );
    final persistSecret = source.indexOf(
      'await _storage.write(key: _pendingSecretKey, value: secret);',
      prepare,
    );
    final post = source.indexOf(
      "_publicUrl('/session/activation-intents')",
      persistSecret,
    );
    expect(persistSecret, greaterThan(prepare));
    expect(post, greaterThan(persistSecret));

    final recover = source.indexOf(
      'static Future<bool> _recoverPendingAbandonmentUnlocked()',
    );
    final activeEquality = source.indexOf(
      'if (activeSecret == secret)',
      recover,
    );
    final cancel = source.indexOf(
      'if (!await _cancelIntent(deviceId, secret))',
      recover,
    );
    final stop = source.indexOf(
      'if (!await _stopExact(deviceId, secret))',
      cancel,
    );
    final clear = source.indexOf('await _clearPending();', stop);
    expect(activeEquality, greaterThan(recover));
    expect(cancel, greaterThan(activeEquality));
    expect(stop, greaterThan(cancel));
    expect(clear, greaterThan(stop));

    final promote = source.indexOf(
      'static Future<bool> confirmAndPromote(SessionActivationIntent intent)',
    );
    final stopPending = source.indexOf(
      'CryptoService.isSessionStopPending()',
      promote,
    );
    final privateHeader = source.indexOf(
      '_sessionNonceHeader: intent.sessionSecret',
      promote,
    );
    final persistActive = source.indexOf(
      'await HivemindService.setSessionNonce(intent.sessionSecret);',
      promote,
    );
    final clearPending = source.indexOf(
      'await _clearPending();',
      persistActive,
    );
    expect(stopPending, greaterThan(promote));
    expect(privateHeader, greaterThan(stopPending));
    expect(persistActive, greaterThan(privateHeader));
    expect(clearPending, greaterThan(persistActive));

    expect(
      source,
      contains('static Future<void> _tail = Future<void>.value();'),
    );
    expect(source, contains('static Future<T> _serialized<T>'));
  });
}
