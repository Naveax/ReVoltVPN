import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_terminal_evidence.dart';

void main() {
  test('inactive status needs explicit Boolean false and success', () {
    expect(
        SessionTerminalEvidence.reportsInactive(200, {'active': false}), true);
    for (final payload in [
      {'active': true},
      {'active': null},
      <String, dynamic>{},
      {'active': 'false'},
      {'ok': true},
      <String, dynamic>{'active': 0},
      null,
      [],
      'false',
    ]) {
      expect(SessionTerminalEvidence.reportsInactive(200, payload), false,
          reason: 'ambiguous payload cannot retire credential: $payload');
    }
    for (final status in [200 + 1, 400, 401, 403, 409, 429, 500, 503]) {
      expect(SessionTerminalEvidence.reportsInactive(status, {'active': false}),
          false);
    }
  });

  test('stop requires explicit acknowledged success, never auth rejection', () {
    expect(SessionTerminalEvidence.confirmedStopped(200, {'ok': true}), true);
    for (final payload in [
      {'ok': false},
      {'ok': null},
      {'ok': 'true'},
      {'active': false},
      <String, dynamic>{},
      null,
      [],
    ]) {
      expect(SessionTerminalEvidence.confirmedStopped(200, payload), false);
    }
    for (final code in [201, 204, 400, 401, 403, 404, 409, 429, 500, 503]) {
      expect(
          SessionTerminalEvidence.confirmedStopped(code, {'ok': true}), false,
          reason: 'HTTP $code must not authorize rotation');
    }
  });
}
