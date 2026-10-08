import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_status_snapshot.dart';

void main() {
  Map<String, dynamic> active() => {
        'active': true,
        'expires_in_seconds': 185,
        'used_bytes': 512,
        'hard_cap_bytes': 2048,
        'cap_exhausted': false,
      };

  test('accepts full Rust active status with strict integer counters', () {
    final s = SessionStatusSnapshot.parseActive(active())!;
    expect(s.remainingSeconds, 185);
    expect(s.usedBytes, 512);
    expect(s.hardCapBytes, 2048);
    expect(s.mustStop, false);
  });

  test('rejects active payload with missing required accounting fields', () {
    for (final key in [
      'active',
      'expires_in_seconds',
      'used_bytes',
      'hard_cap_bytes',
      'cap_exhausted',
    ]) {
      final v = active()..remove(key);
      expect(SessionStatusSnapshot.parseActive(v), null, reason: key);
    }
  });

  test('rejects non-object and inactive payloads', () {
    for (final v in [
      null,
      [],
      'active',
      <String, dynamic>{},
      {'active': false},
      {'active': 'true'},
      {'active': 1},
    ]) {
      expect(SessionStatusSnapshot.parseActive(v), null);
    }
  });

  test('rejects fractional, string and null counters', () {
    for (final key in [
      'expires_in_seconds',
      'used_bytes',
      'hard_cap_bytes',
    ]) {
      for (final bad in <Object?>[null, 1.5, '10', true]) {
        expect(SessionStatusSnapshot.parseActive(active()..[key] = bad), null,
            reason: '$key=$bad');
      }
    }
  });

  test('rejects negative expiry and bytes and nonpositive cap', () {
    for (final change in [
      {'expires_in_seconds': -1},
      {'used_bytes': -1},
      {'hard_cap_bytes': 0},
      {'hard_cap_bytes': -5},
    ]) {
      expect(SessionStatusSnapshot.parseActive(active()..addAll(change)), null);
    }
  });

  test('cap-exhaustion field must be a boolean', () {
    for (final bad in <Object?>[null, 0, 1, 'false', 0.0]) {
      expect(
          SessionStatusSnapshot.parseActive(active()..['cap_exhausted'] = bad),
          null);
    }
  });

  test('zero expiry triggers stop regardless of cap flag', () {
    final s = SessionStatusSnapshot.parseActive(
        active()..['expires_in_seconds'] = 0)!;
    expect(s.mustStop, true);
  });

  test('used byte count equal to or exceeding hard cap triggers stop', () {
    for (final used in [2048, 2049]) {
      final s =
          SessionStatusSnapshot.parseActive(active()..['used_bytes'] = used)!;
      expect(s.mustStop, true);
    }
  });

  test('explicit exhausted status triggers stop even below cap', () {
    final s =
        SessionStatusSnapshot.parseActive(active()..['cap_exhausted'] = true)!;
    expect(s.mustStop, true);
  });
}
