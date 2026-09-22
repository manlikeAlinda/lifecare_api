import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
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
      'patient_code, full_name, phone_e164, is_minor, '
      "LOWER(CONCAT(SUBSTR(HEX(primary_account_id),1,8),'-',SUBSTR(HEX(primary_account_id),9,4),'-',"
      "SUBSTR(HEX(primary_account_id),13,4),'-',SUBSTR(HEX(primary_account_id),17,4),'-',"
      "SUBSTR(HEX(primary_account_id),21))) AS primary_account_id "
      'FROM patients WHERE ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  // ── Low-level mutations — take a live `conn`, called only from the *Tx
  // methods below (never directly from the service), so each action's
  // mutation(s) + its audit entry commit or roll back together on one
  // connection. No external callers outside this file — confirmed by grep.

  Future<void> _insertCredential(
    MySQLConnection conn, {
    required String credentialId,
    required String patientId,
    required String phoneE164,
    required String passwordHash,
    required String activationPinHash,
    int mustChangePw = 1,
  }) async {
    await conn.execute(
      'INSERT INTO patient_credentials '
      '(credential_id, patient_id, phone_e164, password_hash, activation_pin, status, must_change_pw) '
      'VALUES (${uuidParam('credentialId')}, ${uuidParam('patientId')}, '
      ':phoneE164, :passwordHash, :activationPinHash, \'pending_activation\', :mustChangePw)',
      {
        'credentialId': credentialId,
        'patientId': patientId,
        'phoneE164': phoneE164,
        'passwordHash': passwordHash,
        'activationPinHash': activationPinHash,
        'mustChangePw': mustChangePw,
      },
    );
  }

  Future<void> _updateCredential(
    MySQLConnection conn, {
    required String patientId,
    required String passwordHash,
    required String activationPinHash,
    required String status,
    required int mustChangePw,
  }) async {
    await conn.execute(
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

  Future<void> _revokeAllSessions(MySQLConnection conn, String patientId) async {
    await conn.execute(
      'UPDATE patient_sessions SET revoked_at = NOW() '
      'WHERE ${uuidWhere('patient_id', 'patientId')} AND revoked_at IS NULL',
      {'patientId': patientId},
    );
  }

  Future<void> _setStatus(MySQLConnection conn, String patientId, String status) async {
    await conn.execute(
      'UPDATE patient_credentials SET status = :status '
      'WHERE ${uuidWhere('patient_id', 'patientId')}',
      {'patientId': patientId, 'status': status},
    );
  }

  // ── Transactional actions — mutation + writeAudit on one connection ────────

  Future<void> generateCredentialTx({
    required bool isNew,
    required String patientId,
    String? credentialId,
    required String phoneE164,
    required String passwordHash,
    required String activationPinHash,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      if (isNew) {
        await _insertCredential(
          conn,
          credentialId: credentialId!,
          patientId: patientId,
          phoneE164: phoneE164,
          passwordHash: passwordHash,
          activationPinHash: activationPinHash,
          mustChangePw: 1,
        );
      } else {
        await _updateCredential(
          conn,
          patientId: patientId,
          passwordHash: passwordHash,
          activationPinHash: activationPinHash,
          status: 'pending_activation',
          mustChangePw: 0,
        );
        await _revokeAllSessions(conn, patientId);
      }
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'PATIENT_CREDENTIALS_GENERATE',
        targetType: 'patient_credentials',
        targetIdUuid: patientId,
      );
    });
  }

  Future<void> resetCredentialTx({
    required String patientId,
    required String passwordHash,
    required String activationPinHash,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      await _updateCredential(
        conn,
        patientId: patientId,
        passwordHash: passwordHash,
        activationPinHash: activationPinHash,
        status: 'pending_activation',
        mustChangePw: 1,
      );
      await _revokeAllSessions(conn, patientId);
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'PATIENT_CREDENTIALS_RESET',
        targetType: 'patient_credentials',
        targetIdUuid: patientId,
      );
    });
  }

  Future<void> suspendCredentialTx({
    required String patientId,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      await _setStatus(conn, patientId, 'suspended');
      await _revokeAllSessions(conn, patientId);
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'PATIENT_CREDENTIALS_SUSPEND',
        targetType: 'patient_credentials',
        targetIdUuid: patientId,
      );
    });
  }

  Future<void> reinstateCredentialTx({
    required String patientId,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      await _setStatus(conn, patientId, 'active');
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'PATIENT_CREDENTIALS_REINSTATE',
        targetType: 'patient_credentials',
        targetIdUuid: patientId,
      );
    });
  }

  /// No mutation to pair with — a credential *view* is still a real,
  /// auditable event, so it gets the canonical writer too, just without
  /// anything else riding on the same transaction.
  Future<void> auditOnly({
    required String actorId,
    required String patientId,
    required String action,
  }) async {
    await _pool.transactional((conn) async {
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: action,
        targetType: 'patient_credentials',
        targetIdUuid: patientId,
      );
    });
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
