import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/sync_failure_window.dart';

void main() {
  test('failure window expires from first observed failure', () {
    final window = SyncFailureWindow(limit: const Duration(seconds: 120));

    window.recordFailure(const Duration(seconds: 10));
    window.recordFailure(const Duration(seconds: 70));

    expect(window.isExpired(const Duration(seconds: 129)), isFalse);
    expect(window.isExpired(const Duration(seconds: 130)), isTrue);
  });

  test('successful sync reset starts a new failure window', () {
    final window = SyncFailureWindow(limit: const Duration(seconds: 120));

    window.recordFailure(Duration.zero);
    expect(window.isExpired(const Duration(seconds: 120)), isTrue);

    window.reset();
    expect(window.active, isFalse);
    window.recordFailure(const Duration(seconds: 500));
    expect(window.isExpired(const Duration(seconds: 619)), isFalse);
    expect(window.isExpired(const Duration(seconds: 620)), isTrue);
  });

  test('invalid or backwards monotonic time is rejected', () {
    expect(
      () => SyncFailureWindow(limit: Duration.zero),
      throwsArgumentError,
    );

    final window = SyncFailureWindow(limit: const Duration(seconds: 120));
    window.recordFailure(const Duration(seconds: 20));
    expect(
      () => window.isExpired(const Duration(seconds: 19)),
      throwsStateError,
    );
  });
}
