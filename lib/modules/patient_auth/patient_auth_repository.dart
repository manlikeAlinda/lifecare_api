import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientAuthRepository {
  final MySQLConnectionPool _pool;

  PatientAuthRepository(this._pool);

  Future<Map<String, dynamic>?> findByPhone(String phone) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('credential_id')}, '
      '${uuidSelect('patient_id')}, '
      'phone_e164, password_hash, activation_pin, status, must_change_pw, '
      'created_at, updated_at, last_login_at '
      'FROM patient_credentials WHERE phone_e164 = :phone LIMIT 1',
      {'phone': phone},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<void> activateCredential(
    String credentialId,
    String passwordHash,
  ) async {
    await _pool.execute(
      'UPDATE patient_credentials '
      'SET password_hash = :passwordHash, '
      '    activation_pin = NULL, '
      '    status = \'active\', '
      '    must_change_pw = 0, '
      '    last_login_at = NOW() '
      'WHERE ${uuidWhere('credential_id', 'credentialId')}',
      {'passwordHash': passwordHash, 'credentialId': credentialId},
    );
  }

  Future<void> updateLastLogin(String credentialId) async {
    await _pool.execute(
      'UPDATE patient_credentials SET last_login_at = NOW() '
      'WHERE ${uuidWhere('credential_id', 'credentialId')}',
      {'credentialId': credentialId},
    );
  }

  Future<void> insertSession({
    required String sessionId,
    required String patientId,
    required String refreshTokenHash,
    required DateTime expiresAt,
  }) async {
    await _pool.execute(
      'INSERT INTO patient_sessions '
      '(session_id, patient_id, refresh_token_hash, expires_at) '
      'VALUES (${uuidParam('sessionId')}, ${uuidParam('patientId')}, :refreshTokenHash, :expiresAt)',
      {
        'sessionId': sessionId,
        'patientId': patientId,
        'refreshTokenHash': refreshTokenHash,
        'expiresAt': _formatDateTime(expiresAt),
      },
    );
  }

  Future<Map<String, dynamic>?> findSession(String refreshTokenHash) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('session_id')}, '
      '${uuidSelect('patient_id')}, '
      'refresh_token_hash, created_at, expires_at, revoked_at, last_used_at '
      'FROM patient_sessions '
      'WHERE refresh_token_hash = :hash LIMIT 1',
      {'hash': refreshTokenHash},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<void> updateSessionLastUsed(String sessionId) async {
    await _pool.execute(
      'UPDATE patient_sessions SET last_used_at = NOW() '
      'WHERE ${uuidWhere('session_id', 'sessionId')}',
      {'sessionId': sessionId},
    );
  }

  Future<void> revokeSession(String refreshTokenHash) async {
    await _pool.execute(
      'UPDATE patient_sessions SET revoked_at = NOW() '
      'WHERE refresh_token_hash = :hash',
      {'hash': refreshTokenHash},
    );
  }

  Future<void> updatePassword(String patientId, String passwordHash) async {
    await _pool.execute(
      'UPDATE patient_credentials '
      'SET password_hash = :passwordHash, must_change_pw = 0 '
      'WHERE ${uuidWhere('patient_id', 'patientId')}',
      {'passwordHash': passwordHash, 'patientId': patientId},
    );
  }

  Future<Map<String, dynamic>?> findCredentialByPatientId(String patientId) async {
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

  Future<void> insertAuditLog({
    required String patientId,
    required String action,
    String? meta,
  }) async {
    try {
      await _pool.execute(
        'INSERT INTO audit_log '
        '(audit_id, action, target_type, target_id, details) '
        'VALUES (${uuidParam('auditId')}, '
        ':action, :targetType, ${uuidParam('targetId')}, \'{}\')',
        {
          'auditId': generateUuid(),
          'action': action,
          'targetType': 'patient_auth',
          'targetId': patientId,
        },
      );
    } catch (_) {
      // Audit log failures are non-fatal
    }
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);

  String _formatDateTime(DateTime dt) =>
      dt.toUtc().toString().replaceFirst('Z', '').substring(0, 19);
}
