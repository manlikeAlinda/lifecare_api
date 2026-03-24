import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;

  PatientRepository(this._pool);

  // Live DB columns (u524585165_lifecare):
  //   patient_id, patient_code, full_name, phone_e164, national_id_hash,
  //   is_active, created_at, account_type
  // NOTE: national_id, primary_account_id, relationship added by migration 021
  // — omitted here until that migration is applied to the live DB.

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',"
      "SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',"
      "SUBSTR(HEX(patient_id),21))) AS id";

  static const _selectFields =
      'SELECT $_uuidId, patient_code, full_name, phone_e164, '
      'is_active, created_at, account_type '
      'FROM patients';

  // ── Primary-account list (excludes sub-patients) ───────────────────────────

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? search,
    bool activeOnly = true,
  }) async {
    // primary_account_id added by migration 021 — skip filter until applied.
    final conditions = <String>[];
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
    // primary_account_id column added by migration 021 — returns empty until applied.
    return [];
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
    await _pool.transactional((conn) async {
      await conn.execute(
        'INSERT INTO patients '
        '(patient_id, patient_code, full_name, phone_e164, account_type) '
        "VALUES (UNHEX(REPLACE(:id, '-', '')), :patientCode, :fullName, "
        ':phone, :accountType)',
        {
          'id': id,
          'patientCode': patientCode,
          'fullName': fullName,
          'phone': phone,
          'accountType': accountType,
        },
      );

      if (walletId != null) {
        await conn.execute(
          'INSERT INTO wallets (wallet_id, primary_patient_id) '
          "VALUES (UNHEX(REPLACE(:walletId, '-', '')), UNHEX(REPLACE(:patientId, '-', '')))",
          {'walletId': walletId, 'patientId': id},
        );
      }

      final auditId = generateUuid();
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, actor_user_id, action_type, entity_type, entity_id, request_id) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:userId, '-', '')), "
        "  'create_patient', 'patient', UNHEX(REPLACE(:targetId, '-', '')), :requestId)",
        {
          'auditId': auditId,
          'userId': createdBy,
          'targetId': id,
          'requestId': auditId,
        },
      );
    });

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
      'account_type',
      'patient_code',
      'national_id',
      'relationship',
      'is_active',
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
