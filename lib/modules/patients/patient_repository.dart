import 'package:mysql_client/mysql_client.dart';
import 'package:mysql_client/exception.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
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

    // countParams only contains params that appear in the WHERE clause.
    final countParams = <String, dynamic>{};
    // selectParams adds limit/offset on top.
    final selectParams = <String, dynamic>{'limit': limit, 'offset': offset};

    if (activeOnly) conditions.add('is_active = 1');
    if (search != null && search.isNotEmpty) {
      conditions.add(
        '(full_name LIKE :search OR patient_code LIKE :search OR phone_e164 LIKE :search)',
      );
      countParams['search'] = '%$search%';
      selectParams['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM patients $where',
      countParams,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_selectFields $where ORDER BY full_name LIMIT :limit OFFSET :offset',
      selectParams,
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
    try {
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
    } on MySQLServerException catch (e) {
      // 1062 = Duplicate entry — surface as a 409 so the client can show a message.
      if (e.errorCode == 1062) {
        final field = e.message.contains('patient_code') ? 'Account Code' : 'Phone Number';
        throw ApiError.conflict('$field is already in use by another patient');
      }
      rethrow;
    }

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

  /// Hard-deletes a patient and ALL related records.
  ///
  /// Delete order (avoids FK violations):
  ///   1. patient_sessions  (sub-patients + primary)
  ///   2. patient_credentials (sub-patients + primary)
  ///   3. encounters + children (sub-patients + primary; children cascade)
  ///   4. wallet_ledger → wallets (primary only; sub-patients share this wallet)
  ///   5. provider_transactions on this wallet (if table exists)
  ///   6. DELETE patients WHERE primary_account_id = X  (sub-patients)
  ///   7. DELETE patients WHERE patient_id = X          (primary)
  Future<void> hardDelete(String id) async {
    final hex = id.replaceAll('-', '');

    await _pool.transactional((conn) async {
      // 1. Collect sub-patient IDs so we can delete their dependent rows.
      final subResult = await conn.execute(
        "SELECT HEX(patient_id) AS pid FROM patients "
        "WHERE primary_account_id = UNHEX('$hex')",
      );
      final subHexIds = subResult.rows
          .map((r) => r.assoc()['pid'] ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      final allHexIds = [hex, ...subHexIds];

      for (final pid in allHexIds) {
        // 2. Sessions
        await conn.execute(
          "DELETE FROM patient_sessions WHERE patient_id = UNHEX('$pid')",
        );
        // 3. Credentials
        await conn.execute(
          "DELETE FROM patient_credentials WHERE patient_id = UNHEX('$pid')",
        );
        // 4. Encounters (encounter_services / encounter_medications / encounter_drugs
        //    all have ON DELETE CASCADE on encounter_id, so they go automatically).
        await conn.execute(
          "DELETE FROM encounters WHERE patient_id = UNHEX('$pid')",
        );
      }

      // 5. Wallet ledger entries then the wallet itself
      //    (wallet belongs to the primary account; sub-patients share it).
      await conn.execute(
        "DELETE wl FROM wallet_ledger wl "
        "INNER JOIN wallets w ON wl.wallet_id = w.wallet_id "
        "WHERE w.primary_patient_id = UNHEX('$hex')",
      );
      // provider_transactions also references wallet_id — delete if present.
      await conn.execute(
        "DELETE pt FROM provider_transactions pt "
        "INNER JOIN wallets w ON pt.wallet_id = w.wallet_id "
        "WHERE w.primary_patient_id = UNHEX('$hex')",
      );
      await conn.execute(
        "DELETE FROM wallets WHERE primary_patient_id = UNHEX('$hex')",
      );

      // 6 & 7. Sub-patients first (FK), then primary.
      await conn.execute(
        "DELETE FROM patients WHERE primary_account_id = UNHEX('$hex')",
      );
      await conn.execute(
        "DELETE FROM patients WHERE patient_id = UNHEX('$hex')",
      );
    });
  }

  // ── Legacy dependent methods (kept for reference; app now uses sub-patients) ─

  /// @deprecated Use findSubPatients instead.
  Future<List<Map<String, dynamic>>> findDependents(String patientId) =>
      findSubPatients(patientId);

  /// @deprecated Use create with primaryAccountId instead.
  Future<Map<String, dynamic>?> findDependentById(String depId) =>
      findById(depId);

  /// @deprecated Use hardDelete instead.
  Future<void> softDeleteDependent(String depId) async =>
      hardDelete(depId);

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
