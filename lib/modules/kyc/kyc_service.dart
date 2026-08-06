import 'dart:convert';

import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/services/smile_identity_service.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'kyc_repository.dart';

class KycService {
  final KycRepository _repo;
  final SmileIdentityService _smile;

  KycService(this._repo, this._smile);

  Future<Map<String, dynamic>> submit({
    required String patientId,
    required String nationalId,
    required String fullName,
    required String dateOfBirth,
    String? selfieUrl,
    String? idFrontUrl,
    String? idBackUrl,
  }) async {
    final currentStatus = await _repo.getPatientKycStatus(patientId);
    if (currentStatus == 'VERIFIED') {
      throw ApiError.conflict('Account is already KYC verified');
    }
    if (currentStatus == 'PENDING') {
      throw ApiError.conflict('KYC verification already in progress');
    }

    final kycId = generateUuid();
    await _repo.submit(
      kycId: kycId,
      patientId: patientId,
      nationalId: nationalId,
      fullName: fullName,
      dateOfBirth: dateOfBirth,
      selfieUrl: selfieUrl,
      idFrontUrl: idFrontUrl,
      idBackUrl: idBackUrl,
    );

    String? providerJobId;
    if (AppConfig.smileConfigured) {
      final callbackUrl = '${AppConfig.publicUrl}/v1/kyc/webhook';
      providerJobId = await _smile.submitEnhancedKyc(
        kycId: kycId,
        patientId: patientId,
        nationalId: nationalId,
        fullName: fullName,
        dateOfBirth: dateOfBirth,
        callbackUrl: callbackUrl,
      );
      if (providerJobId != null) {
        await _repo.setProviderJobId(kycId, providerJobId);
      }
    } else {
      log.warning(
        'SMILE_PARTNER_ID or SMILE_API_KEY not set — KYC $kycId queued for manual review',
      );
    }

    return {'kycId': kycId, 'status': 'SUBMITTED', 'providerJobId': providerJobId};
  }

  Future<Map<String, dynamic>> getStatus(String patientId) async {
    final row = await _repo.findLatestByPatient(patientId);
    return row ?? {'status': 'NONE'};
  }

  Future<Map<String, dynamic>?> handleWebhook(Map<String, dynamic> payload) async {
    log.info('Smile Identity webhook received: ${jsonEncode(payload)}');

    if (!_smile.verifyWebhookSignature(payload)) {
      log.warning('KYC webhook rejected: invalid or missing signature');
      throw ApiError.forbidden('Invalid webhook signature');
    }

    final jobId = payload['job_id'] as String? ?? payload['SmileJobID'] as String?;
    final resultCode =
        (payload['result_code'] ?? payload['ResultCode'] ?? '').toString();
    final resultText =
        (payload['result_text'] ?? payload['ResultText'] ?? '').toString();

    if (jobId == null) {
      log.warning('KYC webhook missing job_id');
      return null;
    }

    final kyc = await _repo.findByProviderJobId(jobId);
    if (kyc == null) {
      log.warning('KYC webhook for unknown job $jobId');
      return null;
    }

    // Smile Identity result codes: 0810 = Approved, 0820 = Rejected, else = Under Review
    final newStatus = resultCode == '0810'
        ? 'VERIFIED'
        : resultCode == '0820'
            ? 'REJECTED'
            : 'MANUAL_REVIEW';

    await _repo.applyWebhookResult(
      kycId: kyc['kyc_id'] as String,
      patientId: kyc['patient_id'] as String,
      providerJobId: jobId,
      newStatus: newStatus,
      rejectionReason: resultText.isEmpty ? null : resultText,
      auditDetails: jsonEncode({
        'jobId': jobId,
        'resultCode': resultCode,
        'resultText': resultText,
      }),
    );

    return {'kycId': kyc['kyc_id'], 'status': newStatus};
  }
}
