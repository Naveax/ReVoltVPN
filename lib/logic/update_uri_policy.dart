abstract final class UpdateUriPolicy {
  UpdateUriPolicy._();

  static Uri? trustedGitHubRelease({
    required String raw,
    required String owner,
    required String repo,
  }) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      return null;
    }

    final expectedOwner = owner.trim().toLowerCase();
    final expectedRepo = repo.trim().toLowerCase();
    if (expectedOwner.isEmpty || expectedRepo.isEmpty) return null;

    final segments = uri.pathSegments;
    if (segments.length < 4 ||
        segments[0].toLowerCase() != expectedOwner ||
        segments[1].toLowerCase() != expectedRepo ||
        segments[2] != 'releases') {
      return null;
    }

    if (segments.length == 4 && segments[3] == 'latest') return uri;
    if (segments.length == 5 &&
        segments[3] == 'tag' &&
        segments[4].isNotEmpty) {
      return uri;
    }
    return null;
  }
}
