from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one stale assertion, found {count}')
    p.write_text(text.replace(old, new, 1))


replace_once(
    'test/runtime_boundary_regression_test.dart',
    '''  test('notification liveness matches only the ReVolt VPN process', () {
    final source = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      contains(r'val expectedProcessName = "$packageName$VPN_PROCESS_SUFFIX"'),
    );
    expect(source, contains('it.processName == expectedProcessName'));
    expect(source, isNot(contains('endsWith(VPN_PROCESS_SUFFIX)')));
  });
''',
    '''  test('notification updates do not trust ActivityManager process visibility', () {
    final source = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(source, isNot(contains('ActivityManager')));
    expect(source, isNot(contains('isVpnServiceProcessAlive')));
    expect(source, isNot(contains('VPN_PROCESS_SUFFIX')));
    expect(source, contains('NotificationManagerCompat.from(this).notify'));
  });
''',
)

replace_once(
    'test/security_regression_test.dart',
    '''      contains("final pinnedHost = _validatedHost(AppConfig.serverIp, 'serverIp');"),
''',
    '''      contains("final pinnedHost = _validatedPublicIp(AppConfig.serverIp, 'serverIp');"),
''',
)

print('Updated stale regression expectations for the hardened runtime.')
