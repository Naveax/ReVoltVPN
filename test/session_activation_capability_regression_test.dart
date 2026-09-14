import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('H13 activation capability separates public correlation from private auth', () {
    final source = File(
      'lib/logic/session_activation_service.dart',
    ).readAsStringSync();

    expect(source, contains("'h13_pending_session_secret'"));
    expect(source, contains("'h13_pending_activation_id'"));
    expect(source, contains("RegExp(r'^[0-9a-f]{32}\$')"));
    expect(source, contains("'/session/activation-intents'"));
    expect(source, contains("'/session/stop'"));
    expect(source, contains("'X-RevoltVPN-Session-Nonce'"));
    expect(source, contains("'expires_in_seconds'"));
    expect(source, contains('expiresInSeconds != 300'));
    expect(source, contains("contains('no-store')"));

    final prepare = source.indexOf('static Future<SessionActivationIntent?> prepare()');
    final persistSecret = source.indexOf(
      'await _storage.write(key: _pendingSecretKey, value: secret);',
      prepare,
    );
    final preparePost = source.indexOf(
      "_publicUrl('/session/activation-intents')",
      persistSecret,
    );
    final persistActivation = source.indexOf(
      'key: _pendingActivationIdKey,',
      preparePost,
    );
    expect(prepare, greaterThanOrEqualTo(0));
    expect(persistSecret, greaterThan(prepare));
    expect(preparePost, greaterThan(persistSecret));
    expect(persistActivation, greaterThan(preparePost));

    final recover = source.indexOf('static Future<bool> recoverPendingAbandonment()');
    final cancel = source.indexOf('final cancelled = await _cancelIntent', recover);
    final cancelGuard = source.indexOf('if (!cancelled) return false;', cancel);
    final stop = source.indexOf('final stopped = await _stopExact', cancelGuard);
    final stopGuard = source.indexOf('if (!stopped) return false;', stop);
    final clear = source.indexOf('await _clearPending();', stopGuard);
    expect(cancel, greaterThan(recover));
    expect(cancelGuard, greaterThan(cancel));
    expect(stop, greaterThan(cancelGuard));
    expect(stopGuard, greaterThan(stop));
    expect(clear, greaterThan(stopGuard));

    final cancelMethod = source.indexOf('static Future<bool> _cancelIntent');
    final stopMethod = source.indexOf('static Future<bool> _stopExact');
    final privateSecretInPrepare = source.indexOf("'session_secret': secret", prepare);
    final privateSecretInCancel = source.indexOf("'session_secret': secret", cancelMethod);
    expect(privateSecretInPrepare, greaterThan(prepare));
    expect(privateSecretInCancel, greaterThan(cancelMethod));
    expect(stopMethod, greaterThan(cancelMethod));

    final readSecret = source.indexOf('static Future<String?> _readSecret() async');
    final clearPendingMethod = source.indexOf(
      'static Future<void> _clearPending() async',
      readSecret,
    );
    expect(readSecret, greaterThanOrEqualTo(0));
    expect(clearPendingMethod, greaterThan(readSecret));
    final readSecretBody = source.substring(readSecret, clearPendingMethod);
    expect(
      readSecretBody,
      contains("throw const FormatException('Corrupt H13 pending ownership state');"),
    );
    expect(readSecretBody, isNot(contains('_storage.delete')));
    expect(
      source.substring(recover, cancel),
      contains('on FormatException'),
    );

    // The future ad cutover must use activationId as public SSV correlation.
    // This capability file itself never constructs AdMob custom_data.
    expect(source, isNot(contains('ServerSideVerificationOptions')));
    expect(source, isNot(contains("'custom_data'")));
  });
}
