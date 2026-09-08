import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/control_plane_policy.dart';

void main() {
  const base = 'https://api.example.com/api';

  test('accepts configured HTTPS origin with arbitrary API path/query', () {
    final uri = Uri.parse('https://api.example.com/api/session/status?device_id=abc');
    expect(
      ControlPlanePolicy.validate(requested: uri, configuredBase: base),
      same(uri),
    );
  });

  test('rejects cleartext control-plane requests', () {
    expect(
      () => ControlPlanePolicy.validate(
        requested: Uri.parse('http://api.example.com/api/session/status'),
        configuredBase: base,
      ),
      throwsFormatException,
    );
  });

  test('rejects cross-origin control-plane requests', () {
    expect(
      () => ControlPlanePolicy.validate(
        requested: Uri.parse('https://attacker.example/api/session/status'),
        configuredBase: base,
      ),
      throwsFormatException,
    );
  });

  test('rejects userinfo and fragments', () {
    for (final uri in <Uri>[
      Uri.parse('https://user:pass@api.example.com/api/session/status'),
      Uri.parse('https://api.example.com/api/session/status#fragment'),
    ]) {
      expect(
        () => ControlPlanePolicy.validate(requested: uri, configuredBase: base),
        throwsFormatException,
      );
    }
  });

  test('rejects invalid configured control-plane base', () {
    for (final configuredBase in <String>[
      'http://api.example.com/api',
      'https://user@api.example.com/api',
      'https://api.example.com/api?x=1',
      'https://api.example.com/api#fragment',
    ]) {
      expect(
        () => ControlPlanePolicy.validate(
          requested: Uri.parse('https://api.example.com/api/session/status'),
          configuredBase: configuredBase,
        ),
        throwsFormatException,
      );
    }
  });
}
