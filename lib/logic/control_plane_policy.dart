abstract final class ControlPlanePolicy {
  ControlPlanePolicy._();

  static Uri validate({
    required Uri requested,
    required String configuredBase,
  }) {
    final base = Uri.parse(configuredBase);
    _validateBase(base);

    if (requested.scheme != 'https' ||
        requested.host.toLowerCase() != base.host.toLowerCase() ||
        requested.port != base.port ||
        requested.userInfo.isNotEmpty ||
        requested.hasFragment) {
      throw const FormatException(
        'Control-plane request must use the configured HTTPS origin.',
      );
    }
    return requested;
  }

  static void _validateBase(Uri base) {
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasFragment ||
        base.hasQuery) {
      throw const FormatException(
        'Configured control-plane base must be a clean HTTPS origin/path.',
      );
    }
  }
}
