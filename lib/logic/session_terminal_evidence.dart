/// Only an explicit, correctly shaped, successful HTTPS response from the
/// configured control-plane origin may retire a client epoch. Authorization
/// rejection (including an HTTP 401 from an edge proxy) is not proof that a
/// credential was removed from Xray.
abstract final class SessionTerminalEvidence {
  static bool confirmedInactive(int statusCode, Object? body) =>
      statusCode == 200 &&
      body is Map<String, dynamic> &&
      body['active'] == false;

  static bool confirmedStopped(int statusCode, Object? body) =>
      statusCode == 200 && body is Map<String, dynamic> && body['ok'] == true;
}
