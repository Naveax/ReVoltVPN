import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_accounting.dart';

Map<String, dynamic> activeStatus({
  Object expires = 120,
  Object used = 10,
  Object cap = 100,
  Object exhausted = false,
}) => <String, dynamic>{
  'active': true,
  'expires_in_seconds': expires,
  'used_bytes': used,
  'hard_cap_bytes': cap,
  'cap_exhausted': exhausted,
};

void main() {
  test('parses active accounting contract', () {
    final accounting = SessionAccounting.fromActiveStatus(activeStatus());

    expect(accounting.expiresInSeconds, 120);
    expect(accounting.usedBytes, 10);
    expect(accounting.hardCapBytes, 100);
    expect(accounting.capExhausted, isFalse);
    expect(accounting.exhausted, isFalse);
  });

  test('expiry and cap contradictions fail closed', () {
    expect(
      SessionAccounting.fromActiveStatus(activeStatus(expires: 0)).expired,
      isTrue,
    );
    expect(
      SessionAccounting.fromActiveStatus(activeStatus(used: 100)).dataCapReached,
      isTrue,
    );
    expect(
      SessionAccounting.fromActiveStatus(activeStatus(exhausted: true)).dataCapReached,
      isTrue,
    );
  });

  test('malformed accounting fields are rejected', () {
    for (final status in <Map<String, dynamic>>[
      activeStatus(expires: -1),
      activeStatus(expires: 1.5),
      activeStatus(used: -1),
      activeStatus(used: '10'),
      activeStatus(cap: 0),
      activeStatus(cap: 100.0),
      activeStatus(exhausted: 0),
      <String, dynamic>{...activeStatus(), 'active': false},
    ]) {
      expect(
        () => SessionAccounting.fromActiveStatus(status),
        throwsFormatException,
      );
    }
  });
}
