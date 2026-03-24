import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;

  PatientRepository(this._pool);

  // Real DB columns: patient_id (PK), patient_code, full_name, phone_e164,
  // national_id_hash, is_active, created_at, account_type
  // No: first_name, last_name, date_of_birth, gender, email, address, created_by

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',"
      "SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',"
      "SUBSTR(HEX(patient_id),21))) AS id";

  static const _selectFields =
      'SELECT $_uuidId, patient_code, full_name, phone_e164, '
      'is_active, created_at, account_type FROM patients';

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? search,
    bool activeOnly = true,
  }) async {
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

  /// Creates a patient and automatically creates their wallet.
  Future<Map<String, dynamic>> create({
    required String id,
    required String fullName,
    required String createdBy,
    required String walletId,
    String? patientCode,
    String? phone,
    String accountType = 'individual',
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'INSERT INTO patients '
        '(patient_id, patient_code, full_name, phone_e164, account_type) '
        "VALUES (UNHEX(REPLACE(:id, '-', '')), :patientCode, :fullName, :phone, :accountType)",
        {
          'id': id,
          'patientCode': patientCode,
          'fullName': fullName,
          'phone': phone,
          'accountType': accountType,
        },
      );

      await conn.execute(
        'INSERT INTO wallets (wallet_id, primary_patient_id) '
        "VALUES (UNHEX(REPLACE(:walletId, '-', '')), UNHEX(REPLACE(:patientId, '-', '')))",
        {'walletId': walletId, 'patientId': id},
      );

      // Audit
      await conn.execute(
        'INSERT INTO audit_log (audit_id, user_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:userId, '-', '')), "
        "  'create_patient', 'patient', UNHEX(REPLACE(:targetId, '-', '')), '{}')",
        {
          'auditId': generateUuid(),
          'userId': createdBy,
          'targetId': id,
        },
      );
    });

    return (await findById(id))!;
  }

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
      'patient_code'
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

  // ── Dependents ──────────────────────────────────────────────────────────────
  // The real DB dependents table uses wallet_id FK (not patient FK directly).
  // We read via wallet → patient relationship.

  Future<List<Map<String, dynamic>>> findDependents(String patientId) async {
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(d.dependent_id),1,8),'-',SUBSTR(HEX(d.dependent_id),9,4),'-',"
      "SUBSTR(HEX(d.dependent_id),13,4),'-',SUBSTR(HEX(d.dependent_id),17,4),'-',"
      "SUBSTR(HEX(d.dependent_id),21))) AS id, "
      'd.full_name, d.phone_number, d.relationship, d.national_id, d.is_active, d.created_at '
      'FROM dependents d '
      'JOIN wallets w ON d.wallet_id = w.wallet_id '
      "WHERE w.primary_patient_id = UNHEX(REPLACE(:patientId, '-', '')) AND d.is_active = 1",
      {'patientId': patientId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  Future<Map<String, dynamic>?> findDependentById(String depId) async {
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(d.dependent_id),1,8),'-',SUBSTR(HEX(d.dependent_id),9,4),'-',"
      "SUBSTR(HEX(d.dependent_id),13,4),'-',SUBSTR(HEX(d.dependent_id),17,4),'-',"
      "SUBSTR(HEX(d.dependent_id),21))) AS id, "
      'd.full_name, d.phone_number, d.relationship, d.national_id, d.is_active, d.created_at '
      'FROM dependents d '
      "WHERE d.dependent_id = UNHEX(REPLACE(:depId, '-', '')) AND d.is_active = 1 LIMIT 1",
      {'depId': depId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>> createDependent({
    required String patientId,
    required String depId,
    required String fullName,
    required String nationalId,
    required String relationship,
    String? phoneNumber,
  }) async {
    // wallet_id is resolved via the patient's wallet using a subquery.
    await _pool.execute(
      'INSERT INTO dependents (dependent_id, wallet_id, national_id, full_name, phone_number, relationship) '
      "SELECT UNHEX(REPLACE(:depId, '-', '')), wallet_id, :nationalId, :fullName, :phone, :relationship "
      "FROM wallets WHERE primary_patient_id = UNHEX(REPLACE(:patientId, '-', '')) LIMIT 1",
      {
        'depId': depId,
        'patientId': patientId,
        'nationalId': nationalId,
        'fullName': fullName,
        'phone': phoneNumber,
        'relationship': relationship,
      },
    );
    return (await findDependentById(depId))!;
  }

  Future<Map<String, dynamic>?> updateDependent(
    String depId,
    Map<String, dynamic> fields,
  ) async {
    const allowed = ['full_name', 'phone_number', 'relationship', 'national_id'];
    final setClauses =
        fields.keys.where(allowed.contains).map((k) => '$k = :$k').join(', ');
    if (setClauses.isEmpty) return findDependentById(depId);

    final params = Map<String, dynamic>.from(fields)..['depId'] = depId;
    await _pool.execute(
      "UPDATE dependents SET $setClauses WHERE dependent_id = UNHEX(REPLACE(:depId, '-', ''))",
      params,
    );
    return findDependentById(depId);
  }

  Future<void> softDeleteDependent(String depId) async {
    await _pool.execute(
      'UPDATE dependents SET is_active = 0 '
      "WHERE dependent_id = UNHEX(REPLACE(:depId, '-', ''))",
      {'depId': depId},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
