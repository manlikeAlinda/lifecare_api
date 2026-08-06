import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Shared AES-256-GCM helper for at-rest encryption of secrets (TOTP) and
/// PII (patient phone/national ID). Storage format is `iv(12) || authTag(16)
/// || ciphertext`, matching the layout used by the NestJS reference this was
/// ported from, so nothing here is a novel format — just a re-implementation.
final _algorithm = AesGcm.with256bits();

/// Derives a 32-byte key from a raw env-var string via SHA-256, matching
/// `crypto.createHash('sha256').update(rawKey).digest()` on the Node side.
List<int> deriveKey(String rawEnvValue) {
  return crypto.sha256.convert(utf8.encode(rawEnvValue)).bytes;
}

Future<Uint8List> aesGcmEncrypt(List<int> key32, String plaintext) async {
  final secretKey = SecretKey(key32);
  final box = await _algorithm.encrypt(
    utf8.encode(plaintext),
    secretKey: secretKey,
  );
  return Uint8List.fromList([...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

/// Throws if [data] is malformed or the auth tag doesn't verify (tampered
/// ciphertext or wrong key) — callers that must not throw (e.g. PII decrypt
/// on a best-effort read path) should catch and treat as "undecryptable".
Future<String> aesGcmDecrypt(List<int> key32, List<int> data) async {
  if (data.length < 12 + 16) {
    throw const FormatException('Ciphertext too short to contain iv+authTag');
  }
  final nonce = data.sublist(0, 12);
  final mac = Mac(data.sublist(12, 28));
  final cipherText = data.sublist(28);
  final secretKey = SecretKey(key32);
  final clear = await _algorithm.decrypt(
    SecretBox(cipherText, nonce: nonce, mac: mac),
    secretKey: secretKey,
  );
  return utf8.decode(clear);
}
