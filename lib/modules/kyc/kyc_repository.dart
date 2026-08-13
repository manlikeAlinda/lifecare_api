import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class KycRepository {
  final MySQLConnectionPool _pool;

  KycRepository(this._pool);

  Future<String?> getPatientKycStatus(String patientId) async {
    final result = await _pool.execute(
      'SELECT kyc_status FROM patients '
      'WHERE ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return result.rows.first.assoc()['kyc_status'];
  }

  Future<void> submit({
    required String kycId,
    required String patientId,
    required String nationalId,
    required String fullName,
    required String dateOfBirth,
    String? selfieUrl,
    String? idFrontUrl,
    String? idBackUrl,
  }) async {
    await _pool.execute(
      'INSERT INTO kyc_verifications '
      '(kyc_id, patient_id, status, provider, national_id, full_name, '
      ' date_of_birth, selfie_url, id_front_url, id_back_url, submitted_at) '
      "VALUES (${uuidParam('kycId')}, ${uuidParam('patientId')}, 'SUBMITTED', "
      "'SMILE_IDENTITY', :nationalId, :fullName, :dateOfBirth, "
      ':selfieUrl, :idFrontUrl, :idBackUrl, NOW(6))',
      {
        'kycId': kycId,
        'patientId': patientId,
        'nationalId': nationalId,
        'fullName': fullName,
        'dateOfBirth': dateOfBirth,
        'selfieUrl': selfieUrl,
        'idFrontUrl': idFrontUrl,
        'idBackUrl': idBackUrl,
      },
    );
    await _pool.execute(
      "UPDATE patients SET kyc_status = 'PENDING' "
      'WHERE ${uuidWhere('patient_id', 'patientId')}',
      {'patientId': patientId},
    );
  }

  Future<void> setProviderJobId(String kycId, String providerJobId) async {
    await _pool.execute(
      'UPDATE kyc_verifications SET provider_job_id = :jobId '
      'WHERE ${uuidWhere('kyc_id', 'kycId')}',
      {'jobId': providerJobId, 'kycId': kycId},
    );
  }

  Future<Map<String, dynamic>?> findLatestByPatient(String patientId) async {
    final result = await _pool.execute(
      'SELECT ${uuidSelect('kyc_id')}, status, provider, '
      'submitted_at, verified_at, rejection_reason '
      'FROM kyc_verifications WHERE ${uuidWhere('patient_id', 'patientId')} '
      'ORDER BY created_at DESC LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByProviderJobId(String jobId) async {
    final result = await _pool.execute(
      'SELECT ${uuidSelect('kyc_id')}, ${uuidSelect('patient_id')}, status '
      'FROM kyc_verifications WHERE provider_job_id = :jobId LIMIT 1',
      {'jobId': jobId},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  /// Applies a webhook result: updates kyc_verifications + patients.kyc_status
  /// atomically, then writes an audit row (system actor — no real staff or
  /// patient initiated this specific write, the provider did).
  Future<void> applyWebhookResult({
    required String kycId,
    required String patientId,
    required String providerJobId,
    required String newStatus, // VERIFIED | REJECTED | MANUAL_REVIEW
    String? rejectionReason,
    required String auditDetails,
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE kyc_verifications '
        'SET status = :status, '
        "    verified_at = IF(:status = 'VERIFIED', NOW(6), NULL), "
        '    rejection_reason = :reason '
        'WHERE ${uuidWhere('kyc_id', 'kycId')}',
        {'status': newStatus, 'reason': rejectionReason, 'kycId': kycId},
      );

      final patientKycStatus = newStatus == 'MANUAL_REVIEW' ? 'PENDING' : newStatus;
      await conn.execute(
        'UPDATE patients SET kyc_status = :status '
        'WHERE ${uuidWhere('patient_id', 'patientId')}',
        {'status': patientKycStatus, 'patientId': patientId},
      );

      try {
        await conn.execute(
          'INSERT INTO audit_log '
          '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
          "VALUES (${uuidParam('auditId')}, ${uuidParam('patientId')}, "
          "${uuidParam('systemActorId')}, :action, 'kyc_verification', '', "
          ":action, 'kyc_verification', "
          "${uuidParam('kycId')}, :details)",
          {
            'auditId': generateUuid(),
            'patientId': patientId,
            'systemActorId': AppConfig.systemActorId,
            'action': 'KYC_$newStatus',
            'kycId': kycId,
            'details': auditDetails,
          },
        );
      } catch (_) {
        // Audit failure is non-fatal — the KYC state change itself already
        // committed as part of this same transaction's other statements.
      }
    });
  }
}
