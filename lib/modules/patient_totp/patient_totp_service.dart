import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:base32/base32.dart';
import 'package:otp/otp.dart';

import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/aes_gcm.dart';
import '../patient_auth/patient_auth_repository.dart';

/// TOTP 2FA for patient login. SHA1/6-digit/30s — the de facto standard
/// authenticator-app apps (Google Authenticator, Authy, etc.) assume even
/// when an otpauth:// URI specifies otherwise, so this is chosen for
/// interop rather than the `otp` package's SHA256 default.
class PatientTotpService {
  final PatientAuthRepository _repo;

  PatientTotpService(this._repo);

  static const _issuer = 'Lifecare';
  static const _algorithm = Algorithm.SHA1;
  static const _digits = 6;
  static const _interval = 30;
  static const _clockDriftWindows = 1; // tolerate the code from ±30s ago/ahead

  Future<Map<String, dynamic>> setup(String patientId, String phone) async {
    _ensureConfigured();

    // 20 raw bytes (160-bit secret) — stronger than OTP.randomSecret()'s
    // built-in 80-bit default, matching the source feature's strength.
    final rawSecret = Uint8List.fromList(
      List<int>.generate(20, (_) => Random.secure().nextInt(256)),
    );
    final base32Secret = base32.encode(rawSecret).replaceAll('=', '');

    final otpauthUrl = Uri(
      scheme: 'otpauth',
      host: 'totp',
      path: '/$_issuer:$phone',
      queryParameters: {
        'secret': base32Secret,
        'issuer': _issuer,
        'algorithm': 'SHA1',
        'digits': '$_digits',
        'period': '$_interval',
      },
    ).toString();

    final encrypted = await aesGcmEncrypt(
      deriveKey(AppConfig.totpEncryptionKeyRaw),
      base32Secret,
    );
    await _repo.saveTotpSecret(patientId, base64.encode(encrypted));

    return {'otpauthUrl': otpauthUrl, 'secret': base32Secret};
  }

  Future<void> enable(String patientId, String code) async {
    _ensureConfigured();
    final credential = await _repo.findCredentialByPatientId(patientId);
    if (credential == null) throw ApiError.notFound('Credentials not found');

    final secretB64 = credential['totp_secret'] as String?;
    if (secretB64 == null) {
      throw ApiError.businessRule('Call /totp/setup first');
    }

    if (!await _verifyCodeAgainst(secretB64, code)) {
      throw ApiError.forbidden('Invalid verification code');
    }

    await _repo.setTotpEnabled(patientId, true);
  }

  Future<void> disable(String patientId, String code) async {
    final credential = await _repo.findCredentialByPatientId(patientId);
    if (credential == null) throw ApiError.notFound('Credentials not found');
    if (credential['totp_enabled'] != true) {
      throw ApiError.businessRule('Two-factor authentication is not enabled');
    }

    final secretB64 = credential['totp_secret'] as String;
    if (!await _verifyCodeAgainst(secretB64, code)) {
      throw ApiError.forbidden('Invalid verification code');
    }

    await _repo.clearTotpSecret(patientId);
  }

  /// Verifies a login-time code against an already-loaded credential row.
  /// Called from the /totp/verify-login route (not from login() itself —
  /// login() only checks the totp_enabled flag to decide whether to issue
  /// a challenge token instead of full tokens).
  Future<bool> verifyLoginCode(Map<String, dynamic> credential, String code) async {
    final secretB64 = credential['totp_secret'] as String?;
    if (secretB64 == null) return false;
    return _verifyCodeAgainst(secretB64, code);
  }

  Future<bool> _verifyCodeAgainst(String encSecretBase64, String code) async {
    final secret = await aesGcmDecrypt(
      deriveKey(AppConfig.totpEncryptionKeyRaw),
      base64.decode(encSecretBase64),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var drift = -_clockDriftWindows; drift <= _clockDriftWindows; drift++) {
      final t = now + drift * _interval * 1000;
      final expected = OTP.generateTOTPCodeString(
        secret,
        t,
        length: _digits,
        interval: _interval,
        algorithm: _algorithm,
        isGoogle: true,
      );
      if (OTP.constantTimeVerification(expected, code)) return true;
    }
    return false;
  }

  void _ensureConfigured() {
    if (!AppConfig.totpConfigured) {
      throw ApiError.businessRule(
        'Two-factor authentication is not available right now',
      );
    }
  }
}
