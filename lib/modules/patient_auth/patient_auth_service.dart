import 'dart:convert';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/auth/auth_service.dart';
import 'package:lifecare_api/modules/patient_totp/patient_totp_service.dart';
import 'patient_auth_repository.dart';

class PatientAuthService {
  final PatientAuthRepository _repo;
  final AuthService _authService;
  final PatientTotpService _totpService;

  PatientAuthService(this._repo, this._authService, this._totpService);

  /// Called from the first-login activation screen.
  /// Identity is already proved by the JWT — no PIN re-entry required.
  Future<Map<String, dynamic>> activateWithToken({
    required String patientId,
    required String newPassword,
  }) async {
    final credential = await _repo.findCredentialByPatientId(patientId);
    if (credential == null) throw ApiError.notFound('Credentials not found');

    final status = credential['status'] as String;
    final mustChangePw = credential['must_change_pw'] == true;
    if (status != 'pending_activation' && !mustChangePw) {
      throw ApiError.forbidden(
          'Account is already active. Use the change-password endpoint.');
    }

    _validatePassword(newPassword);

    final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt(logRounds: 12));
    await _repo.updatePassword(patientId, newHash);

    await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_ACTIVATE');

    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;
    final phone = patient?['phone_e164'] as String? ?? '';

    final (accessToken, refreshToken, _) = await _createSession(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
      mustChangePw: false,
    );

    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
      'patient_id': patientId,
      'patient_code': patientCode,
    };
  }

  /// [expectBeneficiary] enforces the primary/beneficiary login-endpoint
  /// split: PatientAuthHandler.login() calls this with `false`, the new
  /// beneficiaryLogin() handler calls it with `true`. A phone number that
  /// resolves to the other account type is rejected here — after credential
  /// verification (so it doesn't become a phone-existence oracle beyond
  /// what the suspended-account branch already reveals) but before any
  /// tokens are issued. Both flows share this one implementation so
  /// password/bcrypt/session/audit logic can never drift between them.
  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
    required bool expectBeneficiary,
  }) async {
    final credential = await _repo.findByPhone(phone);
    if (credential == null) {
      // Generic error — do not reveal whether the phone is registered.
      throw ApiError.unauthenticated('Invalid phone number or PIN');
    }

    final status = credential['status'] as String;
    if (status == 'suspended') {
      // Suspended is safe to surface — the user already proved they know the phone.
      throw ApiError.forbidden('Account suspended. Contact the clinic.');
    }

    final credentialId = credential['credential_id'] as String;
    final patientId = credential['patient_id'] as String;
    bool mustChangePw;

    if (status == 'pending_activation') {
      // First-time login: verify the admin-issued PIN.
      final pinHash = credential['activation_pin'] as String?;
      if (pinHash == null || !BCrypt.checkpw(password, pinHash)) {
        await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_LOGIN_FAIL');
        throw ApiError.unauthenticated('Invalid PIN');
      }
      mustChangePw = true; // force them to change PIN after first login
    } else {
      // Active account: verify against the patient's own password/PIN.
      final storedHash = credential['password_hash'] as String;
      if (!BCrypt.checkpw(password, storedHash)) {
        await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_LOGIN_FAIL');
        throw ApiError.unauthenticated('Invalid credentials');
      }
      mustChangePw = credential['must_change_pw'] == true;
    }

    // Account-type check happens after credential verification (so it
    // doesn't become a phone-existence oracle beyond what the
    // suspended-account branch already reveals) but before ANY session or
    // challenge token is issued — including the TOTP challenge below, since
    // verifyTotpLogin() is intentionally type-agnostic and would otherwise
    // let a TOTP-enabled account slip through the wrong endpoint.
    final isBeneficiary = await _repo.isBeneficiary(patientId);
    if (isBeneficiary != expectBeneficiary) {
      await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_LOGIN_WRONG_FLOW');
      throw ApiError.forbidden(expectBeneficiary
          ? 'This phone number belongs to a primary account. Use the primary login.'
          : 'This phone number belongs to a beneficiary account. Use the beneficiary login.');
    }

    // TOTP-enabled accounts don't get full tokens on password verification
    // alone — issue a short-lived challenge instead; verify-login completes
    // the session after the code checks out. last_login_at / audit log for
    // the successful password check itself still happen here since that's
    // a real, completed step regardless of the second factor.
    if (credential['totp_enabled'] == true) {
      await _repo.updateLastLogin(credentialId);
      final challengeToken =
          _authService.issueTotpChallengeToken(patientId: patientId);
      return {'totp_required': true, 'challenge_token': challengeToken};
    }

    await _repo.updateLastLogin(credentialId);

    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;

    final (accessToken, refreshToken, _) = await _createSession(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
      mustChangePw: mustChangePw,
    );

    await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_LOGIN');

    final response = <String, dynamic>{
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
      'patient_id': patientId,
      'patient_code': patientCode,
    };

    if (mustChangePw) {
      response['must_change_password'] = true;
    }

    return response;
  }

  /// Completes a TOTP-gated login: verifies the challenge token issued by
  /// login() plus the authenticator code, then issues real tokens exactly
  /// like a normal successful login would.
  Future<Map<String, dynamic>> verifyTotpLogin({
    required String challengeToken,
    required String code,
  }) async {
    final patientId = _authService.verifyTotpChallengeToken(challengeToken);

    final credential = await _repo.findCredentialByPatientId(patientId);
    if (credential == null) throw ApiError.notFound('Credentials not found');
    if (credential['totp_enabled'] != true) {
      // Account state changed between login() and this call (2FA disabled
      // mid-flow) — the challenge is no longer meaningful.
      throw ApiError.businessRule('Two-factor authentication is not enabled');
    }

    if (!await _totpService.verifyLoginCode(credential, code)) {
      throw ApiError.forbidden('Invalid verification code');
    }

    final mustChangePw = credential['must_change_pw'] == true;
    final phone = credential['phone_e164'] as String;
    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;

    final (accessToken, refreshToken, _) = await _createSession(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
      mustChangePw: mustChangePw,
    );

    await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_LOGIN_TOTP');

    final response = <String, dynamic>{
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
      'patient_id': patientId,
      'patient_code': patientCode,
    };
    if (mustChangePw) response['must_change_password'] = true;
    return response;
  }

  Future<Map<String, dynamic>> refresh(String refreshToken) async {
    final tokenHash = _hashToken(refreshToken);
    final session = await _repo.findSession(tokenHash);

    if (session == null) {
      throw ApiError.unauthenticated('Invalid or expired refresh token');
    }

    final revokedAt = session['revoked_at'];
    if (revokedAt != null &&
        revokedAt.toString().isNotEmpty &&
        revokedAt.toString() != 'null') {
      throw ApiError.unauthenticated('Invalid or expired refresh token');
    }

    final expiresAt =
        DateTime.tryParse(session['expires_at']?.toString() ?? '');
    if (expiresAt == null || expiresAt.isBefore(DateTime.now().toUtc())) {
      throw ApiError.unauthenticated('Invalid or expired refresh token');
    }

    final patientId = session['patient_id'] as String;
    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;
    final phone = patient?['phone_e164'] as String? ?? '';

    // Rotate: delete the consumed token and issue a fresh session.
    await _repo.deleteSession(tokenHash);

    final accessToken = await _authService.issuePatientAccessToken(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
    );

    final newRefreshToken = _generateRefreshToken();
    final newTokenHash = _hashToken(newRefreshToken);
    final newSessionId = generateUuid();
    final newExpiresAt = DateTime.now().toUtc().add(
          Duration(days: AppConfig.jwtRefreshExpiryDays),
        );
    await _repo.insertSession(
      sessionId: newSessionId,
      patientId: patientId,
      refreshTokenHash: newTokenHash,
      expiresAt: newExpiresAt,
    );

    return {
      'access_token': accessToken,
      'refresh_token': newRefreshToken,
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
    };
  }

  Future<void> logout(String refreshToken) async {
    final tokenHash = _hashToken(refreshToken);
    await _repo.revokeSession(tokenHash);
  }

  Future<Map<String, dynamic>> changePassword({
    required String patientId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final credential = await _repo.findCredentialByPatientId(patientId);
    if (credential == null) throw ApiError.notFound('Credentials not found');

    final status = credential['status'] as String;

    if (status == 'pending_activation') {
      // First-time PIN change: verify against the admin-issued activation PIN.
      final pinHash = credential['activation_pin'] as String?;
      if (pinHash == null || !BCrypt.checkpw(currentPassword, pinHash)) {
        throw ApiError.unauthenticated('Invalid PIN');
      }
    } else {
      // Normal PIN change: verify against stored password/PIN.
      final storedHash = credential['password_hash'] as String;
      if (!BCrypt.checkpw(currentPassword, storedHash)) {
        throw ApiError.unauthenticated('Current PIN is incorrect');
      }
    }

    _validatePassword(newPassword);

    final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt(logRounds: 12));
    // updatePassword also sets status='active' and must_change_pw=0.
    await _repo.updatePassword(patientId, newHash);

    await _repo.insertAuditLog(
        patientId: patientId, action: 'PATIENT_CHANGE_PASSWORD');

    return {'message': 'PIN updated successfully'};
  }

  Future<(String, String, String)> _createSession({
    required String patientId,
    required String phone,
    required String patientCode,
    bool mustChangePw = false,
  }) async {
    final accessToken = await _authService.issuePatientAccessToken(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
      mustChangePw: mustChangePw,
    );

    final refreshToken = _generateRefreshToken();
    final refreshTokenHash = _hashToken(refreshToken);
    final sessionId = generateUuid();
    final expiresAt = DateTime.now().toUtc().add(
          Duration(days: AppConfig.jwtRefreshExpiryDays),
        );

    await _repo.insertSession(
      sessionId: sessionId,
      patientId: patientId,
      refreshTokenHash: refreshTokenHash,
      expiresAt: expiresAt,
    );

    return (accessToken, refreshToken, sessionId);
  }

  String _generateRefreshToken() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes);
  }

  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  void _validatePassword(String password) {
    if (password.length < 8) {
      throw ApiError.validationError('Password must be at least 8 characters');
    }
    if (!RegExp(r'\d').hasMatch(password)) {
      throw ApiError.validationError(
          'Password must contain at least one digit');
    }
  }
}
