import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/services/email_service.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/patients/patient_repository.dart';
import 'patient_credentials_repository.dart';

class PatientCredentialsService {
  final PatientCredentialsRepository _repo;
  final PatientRepository _patientRepo;
  final EmailService _emailService;

  PatientCredentialsService(this._repo, this._patientRepo, this._emailService);

  static const _pinChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  Future<Map<String, dynamic>> generate(
    String patientId, {
    String? email,
    required String actorId,
  }) async {
    final patient = await _repo.findPatientById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');

    if (patient['is_minor'] == true) {
      throw ApiError.forbidden(
          'Cannot create login credentials for a minor beneficiary');
    }

    final phoneE164 = patient['phone_e164'] as String?;
    if (phoneE164 == null || phoneE164.isEmpty) {
      throw ApiError.validationError(
          'Patient does not have a phone number on file');
    }

    final patientCode = patient['patient_code'] as String? ?? patientId;
    final pin = _generatePin();
    final pinHash = BCrypt.hashpw(pin, BCrypt.gensalt(logRounds: 12));
    // Use a placeholder password hash — patient must set password on activation
    final passwordHash = BCrypt.hashpw(generateUuid(), BCrypt.gensalt(logRounds: 12));

    final existing = await _repo.findByPatientId(patientId);
    if (existing == null) {
      await _repo.insertCredential(
        credentialId: generateUuid(),
        patientId: patientId,
        phoneE164: phoneE164,
        passwordHash: passwordHash,
        activationPinHash: pinHash,
        mustChangePw: 1,
      );
    } else {
      await _repo.updateCredential(
        patientId: patientId,
        passwordHash: passwordHash,
        activationPinHash: pinHash,
        status: 'pending_activation',
        mustChangePw: 0,
      );
      await _repo.revokeAllSessions(patientId);
    }

    await _repo.insertAuditLog(
      actorId: actorId,
      patientId: patientId,
      action: 'PATIENT_CREDENTIALS_GENERATE',
    );

    // Beneficiary's login-access journey reaches 'active' as soon as
    // credentials exist (see migration 033's state table) — the primary's
    // UI reads this one column without reaching into credential internals.
    // Auto-resolves any open request so the admin queue never lingers a
    // "pending" item after credentials already exist. Primaries stay
    // 'no_login' permanently — that column is only meaningful for
    // beneficiaries, so leave it alone when generating a primary's own
    // credentials.
    if (patient['primary_account_id'] != null) {
      await _patientRepo.setLoginAccessStatus(patientId, 'active');
      await _patientRepo.autoApproveLoginAccessRequest(patientId);
    }

    bool emailSent = false;
    if (email != null && email.isNotEmpty) {
      emailSent = await _emailService.sendActivationEmail(
        toEmail: email,
        patientCode: patientCode,
        pin: pin,
      );
    }

    return {
      'patient_id': patientId,
      'patient_code': patientCode,
      'phone_e164': phoneE164,
      'pin': pin,
      'status': 'pending_activation',
      'email_sent': emailSent,
    };
  }

  Future<Map<String, dynamic>> getCredentials(
    String patientId, {
    required String actorId,
  }) async {
    final patient = await _repo.findPatientById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');

    // Credential views are audited regardless of whether credentials exist
    // yet — an admin looking up a not-yet-provisioned beneficiary is still
    // a "viewed this beneficiary's credential state" event.
    await _repo.insertAuditLog(
      actorId: actorId,
      patientId: patientId,
      action: 'PATIENT_CREDENTIALS_VIEW',
    );

    final credential = await _repo.findByPatientId(patientId);
    if (credential == null) {
      return {'patient_id': patientId, 'provisioned': false};
    }

    final patientCode = patient['patient_code'] as String? ?? patientId;
    final status = credential['status'] as String;

    return {
      'patient_id': patientId,
      'provisioned': true,
      'patient_code': patientCode,
      'phone_e164': credential['phone_e164'],
      'status': status,
      'activation_pin': null, // Plain PIN cannot be recovered from hash
      'last_login_at': credential['last_login_at'],
    };
  }

  Future<Map<String, dynamic>> reset(
    String patientId, {
    String? email,
    required String actorId,
  }) async {
    final credential = await _repo.findByPatientId(patientId);
    if (credential == null) {
      throw ApiError.notFound('No credentials found for this patient');
    }

    final patient = await _repo.findPatientById(patientId);
    final patientCode = patient?['patient_code'] as String? ?? patientId;

    final pin = _generatePin();
    final pinHash = BCrypt.hashpw(pin, BCrypt.gensalt(logRounds: 12));
    final passwordHash = BCrypt.hashpw(generateUuid(), BCrypt.gensalt(logRounds: 12));

    await _repo.updateCredential(
      patientId: patientId,
      passwordHash: passwordHash,
      activationPinHash: pinHash,
      status: 'pending_activation',
      mustChangePw: 1,
    );
    await _repo.revokeAllSessions(patientId);

    await _repo.insertAuditLog(
      actorId: actorId,
      patientId: patientId,
      action: 'PATIENT_CREDENTIALS_RESET',
    );

    bool emailSent = false;
    if (email != null && email.isNotEmpty) {
      emailSent = await _emailService.sendResetEmail(
        toEmail: email,
        patientCode: patientCode,
        pin: pin,
      );
    }

    return {
      'patient_id': patientId,
      'pin': pin,
      'status': 'pending_activation',
      'email_sent': emailSent,
      'message': 'Credentials reset successfully',
    };
  }

  Future<Map<String, dynamic>> suspend(
    String patientId, {
    required String actorId,
  }) async {
    final credential = await _repo.findByPatientId(patientId);
    if (credential == null) {
      throw ApiError.notFound('No credentials found for this patient');
    }

    await _repo.setStatus(patientId, 'suspended');
    await _repo.revokeAllSessions(patientId);
    final patient = await _repo.findPatientById(patientId);
    if (patient?['primary_account_id'] != null) {
      await _patientRepo.setLoginAccessStatus(patientId, 'suspended');
    }

    await _repo.insertAuditLog(
      actorId: actorId,
      patientId: patientId,
      action: 'PATIENT_CREDENTIALS_SUSPEND',
    );

    return {'patient_id': patientId, 'status': 'suspended'};
  }

  Future<Map<String, dynamic>> reinstate(
    String patientId, {
    required String actorId,
  }) async {
    final credential = await _repo.findByPatientId(patientId);
    if (credential == null) {
      throw ApiError.notFound('No credentials found for this patient');
    }

    await _repo.setStatus(patientId, 'active');
    final patient = await _repo.findPatientById(patientId);
    if (patient?['primary_account_id'] != null) {
      await _patientRepo.setLoginAccessStatus(patientId, 'active');
    }

    await _repo.insertAuditLog(
      actorId: actorId,
      patientId: patientId,
      action: 'PATIENT_CREDENTIALS_REINSTATE',
    );

    return {'patient_id': patientId, 'status': 'active'};
  }

  String _generatePin() {
    final rng = Random.secure();
    return List.generate(8, (_) => _pinChars[rng.nextInt(_pinChars.length)])
        .join();
  }
}
