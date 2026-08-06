import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/services/pii_encryption_service.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;
  final PiiEncryptionService _pii;

  PatientRepository(this._pool, this._pii);

  // Live DB columns (migration 024 applied):
  //   patient_id, patient_code, full_name, phone_e164, national_id_hash,
  //   is_active, created_at, account_type,
  //   national_id, primary_account_id, relationship, deleted_at

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
    bool? activeOnly, // null = all, true = active only, false = inactive only
  }) async {
    final conditions = <String>['primary_account_id IS NULL', 'deleted_at IS NULL'];

    // countParams only contains params that appear in the WHERE clause.
    final countParams = <String, dynamic>{};
    // selectParams adds limit/offset on top.
    final selectParams = <String, dynamic>{'limit': limit, 'offset': offset};

    if (activeOnly == true) conditions.add('is_active = 1');
    if (activeOnly == false) conditions.add('is_active = 0');
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
      "$_selectFields WHERE patient_id = UNHEX(REPLACE(:id, '-', '')) "
      'AND deleted_at IS NULL LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByPatientCode(String code) async {
    final result = await _pool.execute(
      '$_selectFields WHERE patient_code = :code AND deleted_at IS NULL LIMIT 1',
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
      'AND deleted_at IS NULL '
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
    // Encrypted alongside plaintext (dual-write) — see PiiEncryptionService.
    // Computed before the transaction since it's just crypto, no DB access.
    final phoneEnc = phone != null ? await _pii.encrypt(phone) : null;
    final nationalIdEnc =
        nationalId != null ? await _pii.encrypt(nationalId) : null;

    // Patient + wallet are atomic; audit is best-effort outside the transaction.
    try {
      await _pool.transactional((conn) async {
        final primaryIdHex = primaryAccountId?.replaceAll('-', '');
        final primaryIdExpr = primaryIdHex != null
            ? "UNHEX('$primaryIdHex')"
            : 'NULL';

        await conn.execute(
          'INSERT INTO patients '
          '(patient_id, patient_code, full_name, phone_e164, phone_enc, '
          ' national_id, nat_id_enc, account_type, primary_account_id, relationship) '
          "VALUES (UNHEX(REPLACE(:id, '-', '')), :patientCode, :fullName, "
          ':phone, :phoneEnc, :nationalId, :nationalIdEnc, :accountType, '
          '$primaryIdExpr, :relationship)',
          {
            'id': id,
            'patientCode': patientCode,
            'fullName': fullName,
            'phone': phone,
            'phoneEnc': phoneEnc,
            'nationalId': nationalId,
            'nationalIdEnc': nationalIdEnc,
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
    } catch (e) {
      if (e.toString().contains('1062')) {
        final field = e.toString().contains('patient_code')
            ? 'Account Code'
            : 'Phone Number';
        throw ApiError.conflict('$field is already in use');
      }
      rethrow;
    }

    // Audit outside transaction — failure must not roll back the patient record.
    try {
      final auditId = generateUuid();
      await _pool.execute(
        'INSERT INTO audit_log '
        '(audit_id, user_id, actor_user_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:userId, '-', '')), "
        "UNHEX(REPLACE(:userId, '-', '')), "
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
    final setClauseParts =
        fields.keys.where(allowed.contains).map((k) => '$k = :$k').toList();

    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    // Re-encrypt alongside the plaintext write, matching create()'s
    // dual-write — an update to phone_e164/national_id must not leave the
    // _enc column stale.
    if (fields.containsKey('phone_e164')) {
      final enc = await _pii.encrypt(fields['phone_e164'] as String);
      if (enc != null) {
        setClauseParts.add('phone_enc = :phoneEnc');
        params['phoneEnc'] = enc;
      }
    }
    if (fields.containsKey('national_id')) {
      final enc = await _pii.encrypt(fields['national_id'] as String);
      if (enc != null) {
        setClauseParts.add('nat_id_enc = :nationalIdEnc');
        params['nationalIdEnc'] = enc;
      }
    }

    if (setClauseParts.isEmpty) return findById(id);

    await _pool.execute(
      "UPDATE patients SET ${setClauseParts.join(', ')} "
      "WHERE patient_id = UNHEX(REPLACE(:id, '-', ''))",
      params,
    );

    return findById(id);
  }

  // ── PII encryption backfill (admin) ─────────────────────────────────────────

  /// Encrypts a batch of rows still missing their _enc column(s). Naturally
  /// idempotent — the WHERE clause only selects rows with at least one NULL
  /// _enc column, so a re-run (after interruption, or picking up rows
  /// created before PII_ENCRYPTION_KEY was set) never re-touches finished
  /// rows. Each row's UPDATE is separately guarded with `WHERE phone_enc IS
  /// NULL` / `nat_id_enc IS NULL` so this can safely race a concurrent
  /// create()/update() without clobbering a fresher encryption.
  Future<Map<String, int>> backfillPiiEncryption({int limit = 200}) async {
    if (!_pii.ready) return {'processed': 0, 'remaining': 0};

    final rows = await _pool.execute(
      'SELECT $_uuidId, phone_e164, national_id, '
      '(phone_enc IS NULL) AS phone_missing, '
      '(nat_id_enc IS NULL) AS national_id_missing '
      'FROM patients '
      'WHERE (phone_enc IS NULL AND phone_e164 IS NOT NULL) '
      '   OR (nat_id_enc IS NULL AND national_id IS NOT NULL) '
      'LIMIT :limit',
      {'limit': limit},
    );

    var processed = 0;
    for (final row in rows.rows) {
      final r = row.assoc();
      final id = r['id']!;
      final phone = r['phone_e164'];
      final nationalId = r['national_id'];
      final phoneMissing = r['phone_missing'] == '1';
      final nationalIdMissing = r['national_id_missing'] == '1';

      if (phoneMissing && phone != null) {
        final enc = await _pii.encrypt(phone);
        if (enc != null) {
          await _pool.execute(
            "UPDATE patients SET phone_enc = :enc "
            "WHERE ${uuidWhere('patient_id', 'id')} AND phone_enc IS NULL",
            {'enc': enc, 'id': id},
          );
        }
      }
      if (nationalIdMissing && nationalId != null) {
        final enc = await _pii.encrypt(nationalId);
        if (enc != null) {
          await _pool.execute(
            "UPDATE patients SET nat_id_enc = :enc "
            "WHERE ${uuidWhere('patient_id', 'id')} AND nat_id_enc IS NULL",
            {'enc': enc, 'id': id},
          );
        }
      }
      processed++;
    }

    final remainingResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM patients '
      'WHERE (phone_enc IS NULL AND phone_e164 IS NOT NULL) '
      '   OR (nat_id_enc IS NULL AND national_id IS NOT NULL)',
      {},
    );
    final remaining = int.parse(remainingResult.rows.first.assoc()['total'] ?? '0');

    return {'processed': processed, 'remaining': remaining};
  }

  /// Hard-deletes a patient and ALL related records.
  ///
  /// Delete order (avoids FK violations):
  ///   1. patient_sessions + patient_credentials (sub-patients + primary)
  ///   2. encounters (cascade-deletes encounter_services/medications/drugs)
  ///   3. legacy dependents rows referencing this wallet (fk_dep_wallet)
  ///   4. wallet_ledger + provider_transactions + wallets
  ///   5. sub-patients, then the primary patient row
  Future<void> hardDelete(String id) async {
    try {
      await _pool.transactional((conn) async {
        // 1. Collect sub-patient UUIDs using a parameterized query.
        final subResult = await conn.execute(
          "SELECT LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',"
          "SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',"
          "SUBSTR(HEX(patient_id),21))) AS pid "
          "FROM patients WHERE primary_account_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        final subIds = subResult.rows
            .map((r) => r.assoc()['pid'] ?? '')
            .where((s) => s.isNotEmpty)
            .toList();

        for (final pid in [id, ...subIds]) {
          await conn.execute(
            "DELETE FROM patient_sessions WHERE patient_id = UNHEX(REPLACE(:pid, '-', ''))",
            {'pid': pid},
          );
          await conn.execute(
            "DELETE FROM patient_credentials WHERE patient_id = UNHEX(REPLACE(:pid, '-', ''))",
            {'pid': pid},
          );
          // encounter_services/medications/drugs cascade from encounter.
          await conn.execute(
            "DELETE FROM encounters WHERE patient_id = UNHEX(REPLACE(:pid, '-', ''))",
            {'pid': pid},
          );
        }

        // 2. Legacy dependents rows still referencing this wallet (migration
        // 021 kept them around for audit/FK history after converting
        // dependents to real patient rows — fk_dep_wallet has no ON DELETE
        // clause, so it blocks the wallet delete below unless cleared first).
        await conn.execute(
          "DELETE d FROM dependents d "
          "INNER JOIN wallets w ON d.wallet_id = w.wallet_id "
          "WHERE w.primary_patient_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );

        // 3. Wallet chain (primary account only; sub-patients share it).
        await conn.execute(
          "DELETE wl FROM wallet_ledger wl "
          "INNER JOIN wallets w ON wl.wallet_id = w.wallet_id "
          "WHERE w.primary_patient_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        await conn.execute(
          "DELETE pt FROM provider_transactions pt "
          "INNER JOIN wallets w ON pt.wallet_id = w.wallet_id "
          "WHERE w.primary_patient_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        await conn.execute(
          "DELETE FROM wallets WHERE primary_patient_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );

        // 4. Sub-patients first (FK), then primary.
        await conn.execute(
          "DELETE FROM patients WHERE primary_account_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        await conn.execute(
          "DELETE FROM patients WHERE patient_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
      });
    } catch (e) {
      if (e.toString().contains('1062')) {
        final field = e.toString().contains('patient_code')
            ? 'Account Code'
            : 'Phone Number';
        throw ApiError.conflict('$field is already in use by another patient');
      }
      rethrow;
    }
  }

  /// Soft-deletes a sub-patient (beneficiary). Unlike [hardDelete], this
  /// leaves encounters and wallet_ledger history intact — the shared wallet's
  /// ledger entries reference wallet_id, not patient_id, so hard-deleting the
  /// beneficiary's encounters would sever the audit trail for a wallet debit
  /// that remains on the books.
  Future<void> softDeleteSubPatient(String id) async {
    await _pool.execute(
      "UPDATE patients SET deleted_at = NOW(6) "
      "WHERE patient_id = UNHEX(REPLACE(:id, '-', '')) AND deleted_at IS NULL",
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

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
