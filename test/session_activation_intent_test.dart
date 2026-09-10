import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_activation_intent.dart';

void main() {
  const activationId = '01234567-89ab-4cde-8fab-0123456789ab';
  const deviceId = '89abcdef-0123-4567-89ab-cdef01234567';

  SessionActivationIntent intent() => SessionActivationIntent.fromJson(
        <String, dynamic>{
          'activation_id': activationId,
          'expires_in_seconds': 300,
        },
      );

  test('parses exact H13 public activation contract', () {
    final activation = intent();

    expect(activation.activationId, activationId);
    expect(activation.expiresInSeconds, 300);
  });

  test('main SSV payload keeps legacy envelope with public UUID only', () {
    final decoded = jsonDecode(intent().toMainSsvCustomData(deviceId));

    expect(
      decoded,
      <String, dynamic>{
        'device_id': deviceId,
        'ad_type': 'main',
        'nonce': activationId,
      },
    );
    expect(decoded.containsKey('activation_id'), isFalse);
    expect(decoded.containsKey('session_secret'), isFalse);
  });

  test('main SSV payload rejects noncanonical device identifiers', () {
    expect(
      () => intent().toMainSsvCustomData(deviceId.toUpperCase()),
      throwsFormatException,
    );
    expect(
      () => intent().toMainSsvCustomData(
        '00000000-0000-0000-0000-000000000000',
      ),
      throwsFormatException,
    );
  });

  test('activation response rejects malformed or overlong lifetime', () {
    expect(
      () => SessionActivationIntent.fromJson(<String, dynamic>{
        'activation_id': activationId.toUpperCase(),
        'expires_in_seconds': 300,
      }),
      throwsFormatException,
    );
    expect(
      () => SessionActivationIntent.fromJson(<String, dynamic>{
        'activation_id': activationId,
        'expires_in_seconds': 301,
      }),
      throwsFormatException,
    );
  });
}
