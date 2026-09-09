import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/native_runtime_state.dart';

void main() {
  test('parses an authoritative active runtime snapshot', () {
    final state = NativeRuntimeState.fromMap(<Object?, Object?>{
      'active': true,
      'runtimeReady': true,
      'proxyOnly': false,
      'runtimeToken': 'runtime-generation-1',
      'state': 'V2RAY_CONNECTED',
    });

    expect(state.active, isTrue);
    expect(state.runtimeReady, isTrue);
    expect(state.ownsGeneration, isTrue);
    expect(state.proxyOnly, isFalse);
    expect(state.runtimeToken, 'runtime-generation-1');
  });

  test('generation token owns startup even before active flag', () {
    final state = NativeRuntimeState.fromMap(<Object?, Object?>{
      'active': false,
      'runtimeReady': false,
      'proxyOnly': true,
      'runtimeToken': 'runtime-generation-starting',
      'state': 'V2RAY_DISCONNECTED',
    });

    expect(state.active, isFalse);
    expect(state.ownsGeneration, isTrue);
  });

  test('rejects active runtime without a generation token', () {
    expect(
      () => NativeRuntimeState.fromMap(<Object?, Object?>{
        'active': true,
        'runtimeReady': false,
        'proxyOnly': false,
        'runtimeToken': '',
        'state': 'V2RAY_CONNECTING',
      }),
      throwsFormatException,
    );
  });

  test('rejects contradictory or malformed runtime snapshots', () {
    expect(
      () => NativeRuntimeState.fromMap(<Object?, Object?>{
        'active': false,
        'runtimeReady': true,
        'proxyOnly': false,
        'runtimeToken': '',
        'state': 'V2RAY_DISCONNECTED',
      }),
      throwsFormatException,
    );
    expect(
      () => NativeRuntimeState.fromMap(<Object?, Object?>{
        'active': 'true',
        'runtimeReady': false,
        'proxyOnly': false,
        'runtimeToken': '',
        'state': 'V2RAY_DISCONNECTED',
      }),
      throwsFormatException,
    );
  });
}
