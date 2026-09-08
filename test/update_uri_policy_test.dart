import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/update_uri_policy.dart';

void main() {
  const owner = 'Naveax';
  const repo = 'ReVoltVPN';

  test('accepts configured repository latest and tag release pages', () {
    for (final raw in <String>[
      'https://github.com/Naveax/ReVoltVPN/releases/latest',
      'https://github.com/naveax/revoltvpn/releases/tag/v3.3.5',
    ]) {
      expect(
        UpdateUriPolicy.trustedGitHubRelease(
          raw: raw,
          owner: owner,
          repo: repo,
        ),
        isNotNull,
      );
    }
  });

  test('rejects another GitHub repository', () {
    expect(
      UpdateUriPolicy.trustedGitHubRelease(
        raw: 'https://github.com/attacker/ReVoltVPN/releases/tag/v9',
        owner: owner,
        repo: repo,
      ),
      isNull,
    );
  });

  test('rejects non-release GitHub paths', () {
    for (final raw in <String>[
      'https://github.com/Naveax/ReVoltVPN/issues/1',
      'https://github.com/Naveax/ReVoltVPN/releases',
      'https://github.com/Naveax/ReVoltVPN/releases/download/v1/app.apk',
    ]) {
      expect(
        UpdateUriPolicy.trustedGitHubRelease(
          raw: raw,
          owner: owner,
          repo: repo,
        ),
        isNull,
      );
    }
  });

  test('rejects cleartext, userinfo, query, and fragment variants', () {
    for (final raw in <String>[
      'http://github.com/Naveax/ReVoltVPN/releases/latest',
      'https://user@github.com/Naveax/ReVoltVPN/releases/latest',
      'https://github.com/Naveax/ReVoltVPN/releases/latest?next=evil',
      'https://github.com/Naveax/ReVoltVPN/releases/latest#fragment',
    ]) {
      expect(
        UpdateUriPolicy.trustedGitHubRelease(
          raw: raw,
          owner: owner,
          repo: repo,
        ),
        isNull,
      );
    }
  });
}
