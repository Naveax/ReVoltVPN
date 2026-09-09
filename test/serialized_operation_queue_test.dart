import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/serialized_operation_queue.dart';

void main() {
  test('operations stay FIFO across await boundaries', () async {
    final queue = SerializedOperationQueue();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = queue.run(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
      return 1;
    });
    final second = queue.run(() async {
      events.add('second');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, <String>['first-start']);

    releaseFirst.complete();
    expect(await first, 1);
    expect(await second, 2);
    expect(events, <String>['first-start', 'first-end', 'second']);
  });

  test('a failed operation does not poison later cleanup', () async {
    final queue = SerializedOperationQueue();

    await expectLater(
      queue.run<void>(() async => throw StateError('boom')),
      throwsStateError,
    );

    expect(await queue.run(() async => 'still-usable'), 'still-usable');
  });
}
