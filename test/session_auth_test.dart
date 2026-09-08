import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_auth.dart';

void main() {
  test('session nonce matches Rust 128-bit lowercase hex contract', () {
    final nonce = SessionAuth.newNonce(random: Random(42));

    expect(nonce, hasLength(32));
    expect(SessionAuth.isValidNonce(nonce), isTrue);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce), isTrue);
  });

  test('session header rejects legacy and malformed nonce formats', () {
    expect(
      () => SessionAuth.headers('123-456-789'),
      throwsFormatException,
    );
    expect(
      () => SessionAuth.headers('ABCDEF0123456789ABCDEF0123456789'),
      throwsFormatException,
    );
    expect(
      SessionAuth.headers('0123456789abcdef0123456789abcdef'),
      <String, String>{
        SessionAuth.headerName: '0123456789abcdef0123456789abcdef',
      },
    );
  });
}
