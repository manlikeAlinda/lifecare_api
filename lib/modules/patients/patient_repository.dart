import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;

  PatientRepository(this._pool);

  // Live DB columns (migration 021 applied):
  //   patient_id, patient_code, full_name, phone_e164, national_id_hash,
  //   is_active, created_at, account_type,
  //   national_id, primary_account_id, relationship

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',"
      "SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',"
      "SUBSTR(HEX(patient_id),21))) AS id";

  // HEX(NULL) = NULL, so no IF() needed — NULLs propagate naturally.
  static const _primaryAccountUuid =
      "LOWER(CONCAT(SUBSTR(HEX(primary_account_id),1,8),'-',SUBSTR(HEX(primary_account_id),9,4),'-',"
      "SUBSTR(HEX(primary_account_id),13,4),'-',SUBSTR(HEX(primary_account_id),17,4),'-',"
      "SUBSTR(HEX(primary_account_id),21)))";

  static const _selectFields =
      'SELECT $_uuidId, patient_code, full_name, phone_e164, national_id, '
      'is_active, created_at, account_type, relationship, '
      '$_primaryAccountUuid AS primary_account_id '
      'FROM patients';

  // ── Primary-account list (excludes sub-patients) ───────────────────────────

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? search,
    bool activeOnly = true,
  }) async {
    final conditions = <String>['primary_account_id IS NULL'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (activeOnly) conditions.add('is_active = 1');
    if (search != null && search.isNotEmpty) {
      conditions.add(
        '(full_name LIKE :search OR patient_code LIKE :search OR phone_e164 LIKE :search)',
      );
      params['search'] = '%$search%';
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM patients $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_selectFields $where ORDER BY full_name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      "$_selectFields WHERE patient_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByPatientCode(String code) async {
    final result = await _pool.execute(
      '$_selectFields WHERE patient_code = :code LIMIT 1',
      {'code': code},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  // ── Sub-patients (beneficiaries of a primary account) ─────────────────────

  Future<List<Map<String, dynamic>>> findSubPatients(
    String primaryAccountId,
  ) async {
    final result = await _pool.execute(
      "$_selectFields WHERE primary_account_id = UNHEX(REPLACE(:id, '-', '')) "
      'ORDER BY full_name',
      {'id': primaryAccountId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  // ── Create ─────────────────────────────────────────────────────────────────

  /// Creates a patient record.
  ///
  /// Pass [walletId] for primary accounts — a wallet row is created atomically.
  /// Omit [walletId] for sub-patients (beneficiaries) — they share the primary
  /// account's wallet and do NOT get their own.
  Future<Map<String, dynamic>> create({
    required String id,
    required String fullName,
    required String createdBy,
    String? walletId,
    String? patientCode,
    String? phone,
    String? nationalId,
    String accountType = 'individual',
    String? primaryAccountId,
    String? relationship,
  }) async {
    // Patient + wallet are atomic; audit is best-effort outside the transaction.
    await _pool.transactional((conn) async {
      final primaryIdHex = primaryAccountId?.replaceAll('-', '');
      final primaryIdExpr = primaryIdHex != null
          ? "UNHEX('$primaryIdHex')"
          : 'NULL';

      await conn.execute(
        'INSERT INTO patients '
        '(patient_id, patient_code, full_name, phone_e164, national_id, '
        ' account_type, primary_account_id, relationship) '
        "VALUES (UNHEX(REPLACE(:id, '-', '')), :patientCode, :fullName, "
        ':phone, :nationalId, :accountType, '
        '$primaryIdExpr, :relationship)',
        {
          'id': id,
          'patientCode': patientCode,
          'fullName': fullName,
          'phone': phone,
          'nationalId': nationalId,
          'accountType': accountType,
          'relationship': relationship,
        },
      );

      if (walletId != null) {
        await conn.execute(
          'INSERT INTO wallets (wallet_id, primary_patient_id, balance_shillings, status) '
          "VALUES (UNHEX(REPLACE(:walletId, '-', '')), UNHEX(REPLACE(:patientId, '-', '')), 0, 'ACTIVE')",
          {'walletId': walletId, 'patientId': id},
        );
      }
    });

    // Audit outside transaction — failure must not roll back the patient record.
    try {
      final auditId = generateUuid();
      await _pool.execute(
        'INSERT INTO audit_log '
        '(audit_id, user_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:userId, '-', '')), "
        "  'create_patient', 'patient', UNHEX(REPLACE(:targetId, '-', '')), '{}')",
        {
          'auditId': auditId,
          'userId': createdBy,
          'targetId': id,
        },
      );
    } catch (_) {
      // Audit failure is non-fatal.
    }

    return (await findById(id))!;
  }

  // ── Update ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
    String updatedBy,
  ) async {
    if (fields.isEmpty) return findById(id);

    final allowed = <String>[
      'full_name',
      'phone_e164',
      'national_id',
      'account_type',
      'patient_code',
      'is_active',
      'relationship',
    ];
    final setClauses =
        fields.keys.where(allowed.contains).map((k) => '$k = :$k').join(', ');

    if (setClauses.isEmpty) return findById(id);

    final params = Map<String, dynamic>.from(fields)..['id'] = id;
    await _pool.execute(
      "UPDATE patients SET $setClauses WHERE patient_id = UNHEX(REPLACE(:id, '-', ''))",
      params,
    );

    return findById(id);
  }

  Future<void> softDelete(String id, String deletedBy) async {
    await _pool.execute(
      'UPDATE patients SET is_active = 0 '
      "WHERE patient_id = UNHEX(REPLACE(:id, '-', ''))",
      {'id': id},
    );
  }

  // ── Legacy dependent methods (kept for reference; app now uses sub-patients) ─

  /// @deprecated Use findSubPatients instead.
  Future<List<Map<String, dynamic>>> findDependents(String patientId) =>
      findSubPatients(patientId);

  /// @deprecated Use create with primaryAccountId instead.
  Future<Map<String, dynamic>?> findDependentById(String depId) =>
      findById(depId);

  /// @deprecated Use softDelete instead.
  Future<void> softDeleteDependent(String depId) async =>
      softDelete(depId, 'system');

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
