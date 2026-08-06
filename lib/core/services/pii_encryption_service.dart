import 'dart:convert';

import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/utils/aes_gcm.dart';

/// AES-256-GCM encryption for patient PII (phone, national ID), keyed by
/// PII_ENCRYPTION_KEY. Ciphertext is returned base64-encoded (ASCII-safe
/// text) — same convention as patient_totp's secret storage — so it can be
/// bound as a normal string query parameter and round-trip safely through
/// mysql_client, which returns every column as a Dart String regardless of
/// the underlying column type.
///
/// Never throws: [encrypt] returns null when unconfigured (caller skips the
/// _enc column write), [tryDecrypt] returns null and logs a warning on any
/// failure (bad key, corrupt ciphertext) rather than taking down a read path
/// over PII that still has a working plaintext column to fall back on.
class PiiEncryptionService {
  bool get ready => AppConfig.piiConfigured;

  Future<String?> encrypt(String plaintext) async {
    if (!ready) return null;
    final bytes = await aesGcmEncrypt(
      deriveKey(AppConfig.piiEncryptionKeyRaw),
      plaintext,
    );
    return base64.encode(bytes);
  }

  Future<String?> tryDecrypt(String? ciphertextBase64) async {
    if (ciphertextBase64 == null || !ready) return null;
    try {
      return await aesGcmDecrypt(
        deriveKey(AppConfig.piiEncryptionKeyRaw),
        base64.decode(ciphertextBase64),
      );
    } catch (e) {
      log.warning('PII decryption failed: $e');
      return null;
    }
  }
}
