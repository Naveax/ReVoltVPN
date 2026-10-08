/// Conservative recovery after native VPN startup cannot establish whether a
/// prior OS tunnel still exists. A local stop does not prove remote revocation,
/// and server revocation does not prove that the local TUN has stopped.
final class VpnStartupRecoveryResult {
  final bool stopIntentPersisted;
  final bool nativeStopVerified;
  final bool remoteRevocationVerified;

  const VpnStartupRecoveryResult({
    required this.stopIntentPersisted,
    required this.nativeStopVerified,
    required this.remoteRevocationVerified,
  });

  bool get completelyVerified =>
      stopIntentPersisted && nativeStopVerified && remoteRevocationVerified;
}

/// Latches restart denial *before the first await*, tries to persist the
/// terminal intent first, then ALWAYS attempts both independent cleanups.
/// Returning successfully does not unlock the in-process safety latch.
final class VpnStartupRecovery {
  static Future<VpnStartupRecoveryResult> quarantine({
    required void Function() denyRestart,
    required Future<void> Function() persistStopIntent,
    required Future<void> Function() stopNative,
    required Future<bool> Function() revokeRemote,
  }) async {
    denyRestart();

    var persisted = false;
    try {
      await persistStopIntent();
      persisted = true;
    } catch (_) {
      // A write failure MUST NOT skip local stop or remote revocation.
    }

    var localStopped = false;
    try {
      await stopNative();
      localStopped = true;
    } catch (_) {
      // An inaccessible native engine is not proof of a stopped TUN.
    }

    var remoteRevoked = false;
    try {
      remoteRevoked = await revokeRemote();
    } catch (_) {
      // A failed authenticated revoke must remain unresolved.
    }

    return VpnStartupRecoveryResult(
      stopIntentPersisted: persisted,
      nativeStopVerified: localStopped,
      remoteRevocationVerified: remoteRevoked,
    );
  }
}
