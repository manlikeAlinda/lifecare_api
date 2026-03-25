import 'dart:convert';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/auth/auth_service.dart';
import 'patient_auth_repository.dart';

class PatientAuthService {
  final PatientAuthRepository _repo;
  final AuthService _authService;

  PatientAuthService(this._repo, this._authService);

  Future<Map<String, dynamic>> activate({
    required String phone,
    required String pin,
    required String newPassword,
  }) async {
    final credential = await _repo.findByPhone(phone);
    if (credential == null) {
      throw ApiError.notFound('No account found for this phone number');
    }

    if (credential['status'] != 'pending_activation') {
      throw ApiError.validationError('Account already activated');
    }

    final storedPinHash = credential['activation_pin'] as String?;
    if (storedPinHash == null || !BCrypt.checkpw(pin, storedPinHash)) {
      throw ApiError.unauthenticated('Invalid PIN');
    }

    _validatePassword(newPassword);

    final passwordHash = BCrypt.hashpw(newPassword, BCrypt.gensalt(logRounds: 12));
    final credentialId = credential['credential_id'] as String;
    final patientId = credential['patient_id'] as String;

    await _repo.activateCredential(credentialId, passwordHash);

    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;

    final (accessToken, refreshToken, _) = await _createSession(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
    );

    await _repo.insertAuditLog(patientId: patientId, action: 'PATIENT_ACTIVATE');

    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
      'patient_id': patientId,
      'patient_code': patientCode,
    };
  }

  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
  }) async {
    final credential = await _repo.findByPhone(phone);
    if (credential == null) {
      throw ApiError.notFound('No account found for this phone number');
    }

    final status = credential['status'] as String;
    if (status == 'suspended') {
      throw ApiError.forbidden('Account suspended. Contact the clinic.');
    }

    final credentialId = credential['credential_id'] as String;
    final patientId = credential['patient_id'] as String;
    bool mustChangePw;

    if (status == 'pending_activation') {
      // First-time login: verify the admin-issued PIN.
      final pinHash = credential['activation_pin'] as String?;
      if (pinHash == null || !BCrypt.checkpw(password, pinHash)) {
        throw ApiError.unauthenticated('Invalid PIN');
      }
      mustChangePw = true; // force them to change PIN after first login
    } else {
      // Active account: verify against the patient's own password/PIN.
      final storedHash = credential['password_hash'] as String;
      if (!BCrypt.checkpw(password, storedHash)) {
        throw ApiError.unauthenticated('Invalid credentials');
      }
      mustChangePw = credential['must_change_pw'] == true;
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

    final sessionId = session['session_id'] as String;
    await _repo.updateSessionLastUsed(sessionId);

    final patientId = session['patient_id'] as String;
    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;
    final phone = patient?['phone_e164'] as String? ?? '';

    final accessToken = await _authService.issuePatientAccessToken(
      patientId: patientId,
      phone: phone,
      patientCode: patientCode,
    );

    return {
      'access_token': accessToken,
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
