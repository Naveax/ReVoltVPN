import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/network_privacy.dart';
import 'package:revoltvpn/logic/session_terminal_evidence.dart';

enum SessionProbeResult { active, inactive, unavailable }

enum SessionStopResult { stopped, alreadyInactive, retryNeeded }

enum CandidateLifecycleState {
  pending,
  activating,
  active,
  absent,
  unavailable
}

enum PendingCandidateRecovery { none, active, unresolved }

class HivemindService {
  static int _currentCallId = 0;
  static final Random _secureRandom = Random.secure();
  static Future<SessionStopResult>? _stopInFlight;

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';
  static final RegExp _canonicalSessionNonce = RegExp(r'^[0-9a-f]{32}$');

  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return _sendNoRedirect('GET', uri, timeout: timeout, headers: headers);
  }

  static Future<http.Response> directPost(
    Uri uri, {
    required String body,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return _sendNoRedirect(
      'POST',
      uri,
      timeout: timeout,
      headers: {'Content-Type': 'application/json', ...?headers},
      body: body,
    );
  }

  static Future<http.Response> _sendNoRedirect(
    String method,
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
    String? body,
  }) async {
    _validateApiUri(uri);
    final client = http.Client();
    try {
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll({'User-Agent': _ua, ...?headers});
      if (body != null) request.body = body;

      final streamed = await client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } finally {
      client.close();
    }
  }

  static String newNonce() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Reserve one exact main-session capability. Existing durable candidate ownership
  /// must first be resolved by [recoverPendingSessionCandidate]; it is never cancelled
  /// blindly because a delayed signed SSV may already have consumed it into a live session.
  /// The new capability is persisted before the network reservation so a crash or lost
  /// response can be reconciled through the exact candidate status boundary after restart.
  static Future<bool> reserveSessionCandidate(String nonce) async {
    if (!_canonicalSessionNonce.hasMatch(nonce)) return false;

    try {
      // This lock-protected claim rotates an eligible epoch and persists its
      // candidate together. No competing caller can mint a second nonce or
      // see the new pseudonym without its durable candidate owner.
      final deviceId = await CryptoService.beginMainSessionCandidate(nonce);
      if (deviceId == null) return false;

      try {
        final response = await directPost(
          _publicUrl('/session/candidate'),
          body: jsonEncode({'device_id': deviceId, 'operation': 'register'}),
          timeout: const Duration(seconds: 4),
          headers: {_sessionNonceHeader: nonce},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['ok'] == true) {
            return true;
          }
        }
      } catch (_) {}

      // A definitive or ambiguous registration failure is cleaned up only through the
      // candidate-only operation. If that cleanup is itself ambiguous, durable ownership
      // remains so the next process can probe/recover instead of minting another nonce.
      await cancelSessionCandidate(nonce);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Inspect only the exact pre-activation capability lifecycle. This endpoint never
  /// returns VPN credentials and is used to distinguish delayed SSV from an expired orphan.
  static Future<CandidateLifecycleState> probeSessionCandidate(
      String nonce) async {
    if (!_canonicalSessionNonce.hasMatch(nonce)) {
      return CandidateLifecycleState.unavailable;
    }

    try {
      final deviceId = await CryptoService.getDeviceId();
      final response = await directPost(
        _publicUrl('/session/candidate'),
        body: jsonEncode({'device_id': deviceId, 'operation': 'status'}),
        timeout: const Duration(seconds: 4),
        headers: {_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) {
        return CandidateLifecycleState.unavailable;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return CandidateLifecycleState.unavailable;
      }
      switch (data['state']) {
        case 'pending':
          return CandidateLifecycleState.pending;
        case 'activating':
          return CandidateLifecycleState.activating;
        case 'active':
          return CandidateLifecycleState.active;
        case 'absent':
          return CandidateLifecycleState.absent;
        default:
          return CandidateLifecycleState.unavailable;
      }
    } catch (_) {
      return CandidateLifecycleState.unavailable;
    }
  }

  /// Converge a durable candidate left behind by a timeout, process death, or delayed SSV.
  /// Pending/activating states fail closed. Active state is promoted to possession; only an
  /// explicit server-side absent state permits forgetting the local candidate.
  static Future<PendingCandidateRecovery>
      recoverPendingSessionCandidate() async {
    final pending = await CryptoService.getPendingSessionCandidate();
    if (pending == null) return PendingCandidateRecovery.none;

    final state = await probeSessionCandidate(pending);
    switch (state) {
      case CandidateLifecycleState.active:
        if (await confirmAndSetSessionNonce(pending)) {
          return PendingCandidateRecovery.active;
        }
        return PendingCandidateRecovery.unresolved;
      case CandidateLifecycleState.absent:
        return await CryptoService.releaseCandidateIfOwned(pending)
            ? PendingCandidateRecovery.none
            : PendingCandidateRecovery.unresolved;
      case CandidateLifecycleState.pending:
      case CandidateLifecycleState.activating:
      case CandidateLifecycleState.unavailable:
        return PendingCandidateRecovery.unresolved;
    }
  }

  /// Cancel a reservation through the candidate-only server operation. The server holds
  /// the same per-device gate as signed SSV and returns 409 instead of stopping a nonce that
  /// has already crossed into provisioning/active state.
  static Future<bool> cancelSessionCandidate(String nonce) async {
    if (!_canonicalSessionNonce.hasMatch(nonce)) return false;

    try {
      final deviceId = await CryptoService.getDeviceId();
      if (!await _cancelSessionCandidateRemote(deviceId, nonce)) return false;

      return await CryptoService.releaseCandidateIfOwned(nonce);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _cancelSessionCandidateRemote(
    String deviceId,
    String nonce,
  ) async {
    try {
      final response = await directPost(
        _publicUrl('/session/candidate'),
        body: jsonEncode({'device_id': deviceId, 'operation': 'cancel'}),
        timeout: const Duration(seconds: 4),
        headers: {_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      return data is Map<String, dynamic> && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static void cancel() {
    _currentCallId++;
  }

  static Future<bool> _promoteSessionCandidate(String nonce) =>
      CryptoService.promoteSessionCandidate(nonce);

  // Do not cache the durable possession token in process memory. A delayed
  // read racing terminal cleanup must never resurrect an already removed
  // authorization credential for later authenticated calls.
  static Future<String?> getSessionNonce() => CryptoService.getSessionNonce();

  static Future<void> clearSessionNonce() async {
    await CryptoService.clearSessionNonce();
    await CryptoService.clearSessionStopPending();
  }

  static Future<http.Response> authenticatedGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final nonce = await getSessionNonce();
    if (nonce == null) {
      throw Exception('Session authorization unavailable.');
    }
    return directGet(
      uri,
      timeout: timeout,
      headers: {_sessionNonceHeader: nonce},
    );
  }

  static Future<SessionProbeResult> probeCurrentSession() async {
    final nonce = await getSessionNonce();
    if (nonce == null) return SessionProbeResult.inactive;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final response = await directGet(
        _publicUrl('/session/status?device_id=$deviceId'),
        timeout: const Duration(seconds: 3),
        headers: {_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) {
        return SessionProbeResult.unavailable;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return SessionProbeResult.unavailable;
      }
      if (data['active'] == true) {
        final serverNonce = data['nonce'] as String?;
        if (serverNonce != null && serverNonce != nonce) {
          return SessionProbeResult.unavailable;
        }
        return SessionProbeResult.active;
      }
      // Missing or malformed status is not proof of terminal teardown.
      if (!SessionTerminalEvidence.reportsInactive(response.statusCode, data)) {
        return SessionProbeResult.unavailable;
      }

      // The public status endpoint returns active:false for missing/mismatched
      // auth and fail-closed latch states too. Only the explicit stop operation
      // converges teardown/cancellation under the server's device gate.
      final stop = await stopSession();
      return stop == SessionStopResult.retryNeeded
          ? SessionProbeResult.unavailable
          : SessionProbeResult.inactive;
    } catch (_) {
      return SessionProbeResult.unavailable;
    }
  }

  static Future<bool> confirmAndSetSessionNonce(String nonce) async {
    if (await CryptoService.getPendingSessionCandidate() != nonce) return false;

    final deviceId = await CryptoService.getDeviceId();
    final url = _publicUrl('/session/status?device_id=$deviceId');

    const maxAttempts = 8;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directGet(
          url,
          timeout: const Duration(seconds: 2),
          headers: {_sessionNonceHeader: nonce},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['active'] == true) {
            final serverNonce = data['nonce'] as String?;
            if (serverNonce == null || serverNonce == nonce) {
              if (!await _promoteSessionCandidate(nonce)) {
                return false;
              }
              // A concurrent user disconnect is authoritative. Do not erase
              // its durable stop marker merely because SSV became active.
              // The retry path will revoke the promoted server capability.
              if (await CryptoService.isSessionStopPending()) return false;
              return true;
            }
            return false;
          }
        }
      } catch (_) {}

      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 750));
      }
    }

    return false;
  }

  static Future<SessionStopResult> stopSession({
    bool markPending = true,
  }) async {
    final existing = _stopInFlight;
    if (existing != null) return existing;

    final operation = _stopSessionInner(markPending: markPending);
    _stopInFlight = operation;
    try {
      return await operation;
    } finally {
      if (identical(_stopInFlight, operation)) {
        _stopInFlight = null;
      }
    }
  }

  static Future<SessionStopResult> _stopSessionInner({
    required bool markPending,
  }) async {
    // Persist stop intent before inspecting possession. A candidate may be
    // promoting concurrently; absence of a readable nonce is not proof that
    // the server has no credential or delayed SSV activation.
    if (markPending) await CryptoService.setSessionStopPending();
    final nonce = await getSessionNonce();
    if (nonce == null) {
      return await CryptoService.clearStopIntentIfNoOwnership()
          ? SessionStopResult.alreadyInactive
          : SessionStopResult.retryNeeded;
    }

    final deviceId = await CryptoService.getDeviceId();
    final url = _publicUrl('/session/stop');
    final body = jsonEncode({'device_id': deviceId});

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directPost(
          url,
          body: body,
          timeout: const Duration(seconds: 4),
          headers: {_sessionNonceHeader: nonce},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (SessionTerminalEvidence.confirmedStopped(
              response.statusCode, data)) {
            await CryptoService.acknowledgeClientEpochTerminal();
            await clearSessionNonce();
            return SessionStopResult.stopped;
          }
        } else if (response.statusCode == 401) {
          // HTTP authentication rejection is not a teardown receipt. The edge
          // can reject a request without touching the live Xray credential.
          // Retain the possession nonce and durable stop intent for retry.
          return SessionStopResult.retryNeeded;
        }
      } catch (_) {}

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    return SessionStopResult.retryNeeded;
  }

  static Future<bool> retryPendingSessionStop() async {
    if (!await CryptoService.isSessionStopPending()) return true;
    // A prior disconnect can race signed SSV before an active token is
    // persisted. Recover the exact candidate, then stop its live credential.
    // Pending/activating/unavailable states keep durable stop intent.
    if (await getSessionNonce() == null &&
        await CryptoService.getPendingSessionCandidate() != null) {
      await recoverPendingSessionCandidate();
    }
    final result = await stopSession(markPending: false);
    return result != SessionStopResult.retryNeeded;
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    var deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;

    var nonce = await getSessionNonce();
    if (nonce == null && !skipAdBypass && kDebugMode) {
      final recovery = await recoverPendingSessionCandidate();
      if (recovery == PendingCandidateRecovery.active) {
        nonce = await getSessionNonce();
      } else if (recovery == PendingCandidateRecovery.unresolved) {
        throw Exception('Session candidate recovery is still pending.');
      }
    }
    if (nonce == null && !skipAdBypass && kDebugMode) {
      // Reservation below atomically rotates and persists a fresh candidate.
      // Candidate recovery above must finish before entering that operation.
      final candidate = newNonce();
      try {
        if (!await reserveSessionCandidate(candidate)) {
          throw Exception('Session candidate reservation unavailable.');
        }
        // After the atomic reservation, read the claimed epoch for SSV.
        deviceId = await CryptoService.getDeviceId();
        final customData = jsonEncode({
          'device_id': deviceId,
          'nonce': candidate,
        });
        final fakeUrl = _publicUrl(
          '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}',
        );
        final response = await directGet(
          fakeUrl,
          timeout: const Duration(seconds: 8),
        );
        if (response.statusCode == 200 &&
            await confirmAndSetSessionNonce(candidate)) {
          nonce = candidate;
        }
      } catch (_) {}
    }
    if (nonce == null) {
      throw Exception('Session authorization unavailable.');
    }

    final url = _publicUrl('/session/status?device_id=$deviceId');

    const maxAttempts = 5;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await directGet(
          url,
          headers: {_sessionNonceHeader: nonce},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final serverNonce = data['nonce'] as String?;
          if (serverNonce != null && serverNonce != nonce) {
            debugPrint(
              '[HivemindService] Session authorization mismatch — retrying…',
            );
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];
            final vlessHost = NetworkPrivacy.vlessAuthorityHost(
              data['vless_ip'] ?? AppConfig.serverIp,
            );
            final vlessPort = NetworkPrivacy.vlessPort(data['vless_port']);
            final pbk = data['reality_pbk'] ?? '';
            final sid = data['reality_sid'] ?? '';
            final sni = data['reality_sni'];
            if (sni == null) {
              throw Exception('Server did not provide reality_sni');
            }
            final fp = data['reality_fp'] ?? AppConfig.realityFp;
            final xhttpPath = data['xhttp_path'] ?? AppConfig.vlessPath;

            final vlessUrl = 'vless://$vlessUuid@$vlessHost:$vlessPort'
                '?security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '&path=$xhttpPath'
                '&pbk=${Uri.encodeComponent(pbk)}'
                '&sni=${Uri.encodeComponent(sni)}'
                '&sid=${Uri.encodeComponent(sid)}'
                '&fp=${Uri.encodeComponent(fp)}'
                '#Revolt VPN';
            return vlessUrl;
          }
        }
      } catch (e) {
        if (e.toString().contains('Cancelled')) rethrow;
        debugPrint('[HivemindService] Attempt $i failed: $e');
      }

      if (i < maxAttempts) await Future.delayed(const Duration(seconds: 1));
    }

    throw Exception(
      'Session not activated. Server callback may have timed out.',
    );
  }

  static Future<bool> checkHealth() async {
    try {
      final response = await directGet(
        _publicUrl('/health'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Uri _configuredApiBase() {
    final base = Uri.tryParse(AppConfig.hivemindApiPublic.trim());
    if (base == null ||
        base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw StateError('hivemindApiPublic must be a canonical HTTPS base URL.');
    }
    return base;
  }

  static void _validateApiUri(Uri uri) {
    final base = _configuredApiBase();
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.origin != base.origin) {
      throw ArgumentError.value(
        uri,
        'uri',
        'API requests must remain on the configured HTTPS origin',
      );
    }
  }

  static Uri _publicUrl(String path) {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError.value(path, 'path', 'expected an absolute API path');
    }

    final base = _configuredApiBase();
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    final uri = Uri.parse('$baseText$path');
    _validateApiUri(uri);
    return uri;
  }
}
