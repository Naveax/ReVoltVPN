import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _privKeyPref = 'wg_private_key';
  static const String _pubKeyPref = 'wg_public_key';
  static const String _deviceIdPref = 'device_uuid';

  static const _storage = FlutterSecureStorage();

  // ── Get or create the persistent device UUID ──────────────────────────────
  static Future<String> getDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    if (existing != null) return existing;

    final newId = const Uuid().v4();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }

  // ── Get or create the X25519 keypair for WireGuard ────────────────────────
  static Future<Map<String, String>> getOrCreateKeys() async {
    String? privBase64 = await _storage.read(key: _privKeyPref);
    String? pubBase64 = await _storage.read(key: _pubKeyPref);

    if (privBase64 != null && pubBase64 != null) {
      return {'privateKey': privBase64, 'publicKey': pubBase64};
    }

    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    
    privBase64 = base64Encode(privateKeyBytes);
    pubBase64 = base64Encode(publicKey.bytes);

    await _storage.write(key: _privKeyPref, value: privBase64);
    await _storage.write(key: _pubKeyPref, value: pubBase64);

    return {'privateKey': privBase64, 'publicKey': pubBase64};
  }
}
