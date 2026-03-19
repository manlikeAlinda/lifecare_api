import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientCredentialsRepository {
  final MySQLConnectionPool _pool;

  PatientCredentialsRepository(this._pool);

  Future<Map<String, dynamic>?> findByPatientId(String patientId) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('credential_id')}, '
      '${uuidSelect('patient_id')}, '
      'phone_e164, password_hash, activation_pin, status, must_change_pw, '
      'created_at, updated_at, last_login_at '
      'FROM patient_credentials WHERE ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findPatientById(String patientId) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('patient_id')}, '
      'patient_code, full_name, phone_e164 '
      'FROM patients WHERE ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<void> insertCredential({
    required String credentialId,
    required String patientId,
    required String phoneE164,
    required String passwordHash,
    required String activationPinHash,
  }) async {
    await _pool.execute(
      'INSERT INTO patient_credentials '
      '(credential_id, patient_id, phone_e164, password_hash, activation_pin, status, must_change_pw) '
      'VALUES (${uuidParam('credentialId')}, ${uuidParam('patientId')}, '
      ':phoneE164, :passwordHash, :activationPinHash, \'pending_activation\', 0)',
      {
        'credentialId': credentialId,
        'patientId': patientId,
        'phoneE164': phoneE164,
        'passwordHash': passwordHash,
        'activationPinHash': activationPinHash,
      },
    );
  }

  Future<void> updateCredential({
    required String patientId,
    required String passwordHash,
    required String activationPinHash,
    required String status,
    required int mustChangePw,
  }) async {
    await _pool.execute(
      'UPDATE patient_credentials '
      'SET password_hash = :passwordHash, '
      '    activation_pin = :activationPinHash, '
      '    status = :status, '
      '    must_change_pw = :mustChangePw '
      'WHERE ${uuidWhere('patient_id', 'patientId')}',
      {
        'patientId': patientId,
        'passwordHash': passwordHash,
        'activationPinHash': activationPinHash,
        'status': status,
        'mustChangePw': mustChangePw,
      },
    );
  }

  Future<void> revokeAllSessions(String patientId) async {
    await _pool.execute(
      'UPDATE patient_sessions SET revoked_at = NOW() '
      'WHERE ${uuidWhere('patient_id', 'patientId')} AND revoked_at IS NULL',
      {'patientId': patientId},
    );
  }

  Future<void> setStatus(String patientId, String status) async {
    await _pool.execute(
      'UPDATE patient_credentials SET status = :status '
      'WHERE ${uuidWhere('patient_id', 'patientId')}',
      {'patientId': patientId, 'status': status},
    );
  }

  Future<void> insertAuditLog({
    required String actorId,
    required String patientId,
    required String action,
  }) async {
    try {
      await _pool.execute(
        'INSERT INTO audit_log '
        '(audit_id, actor_user_id, action_type, entity_type, entity_id, request_id) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('actorId')}, '
        ':actionType, :entityType, ${uuidParam('entityId')}, :requestId)',
        {
          'auditId': generateUuid(),
          'actorId': actorId,
          'actionType': action,
          'entityType': 'patient_credentials',
          'entityId': patientId,
          'requestId': generateUuid(),
        },
      );
    } catch (_) {
      // Audit log failures are non-fatal
    }
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
