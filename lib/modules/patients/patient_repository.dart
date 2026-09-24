import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/services/pii_encryption_service.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;
  final PiiEncryptionService _pii;
  final WalletRepository _walletRepo;

  PatientRepository(this._pool, this._pii, this._walletRepo);

  // Live DB columns (migration 024 applied):
  //   patient_id, patient_code, full_name, phone_e164, national_id_hash,
  //   is_active, created_at, account_type,
  //   national_id, primary_account_id, relationship, deleted_at
  //   cost_centre_id (039), allocated_budget_shillings (040)

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',"
      "SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',"
      "SUBSTR(HEX(patient_id),21))) AS id";

  // HEX(NULL) = NULL, so no IF() needed — NULLs propagate naturally.
  static const _primaryAccountUuid =
      "LOWER(CONCAT(SUBSTR(HEX(primary_account_id),1,8),'-',SUBSTR(HEX(primary_account_id),9,4),'-',"
      "SUBSTR(HEX(primary_account_id),13,4),'-',SUBSTR(HEX(primary_account_id),17,4),'-',"
      "SUBSTR(HEX(primary_account_id),21)))";

  static const _costCentreUuid =
      "LOWER(CONCAT(SUBSTR(HEX(cost_centre_id),1,8),'-',SUBSTR(HEX(cost_centre_id),9,4),'-',"
      "SUBSTR(HEX(cost_centre_id),13,4),'-',SUBSTR(HEX(cost_centre_id),17,4),'-',"
      "SUBSTR(HEX(cost_centre_id),21)))";

  static const _selectFields =
      'SELECT $_uuidId, patient_code, full_name, phone_e164, national_id, '
      'nat_id_enc, '
      'is_active, created_at, account_type, relationship, is_minor, '
      'login_access_status, id_type, allocated_budget_shillings, '
      '$_primaryAccountUuid AS primary_account_id, '
      '$_costCentreUuid AS cost_centre_id '
      'FROM patients';

  /// TIN (`id_type == 'tin'`) is encrypted-only — see create()/update() —
  /// so unlike every other id_type, its value has to be decrypted back out
  /// of nat_id_enc into national_id for display. Applied after every
  /// [_selectFields] read since nat_id_enc is now in that query; always
  /// strips nat_id_enc from the returned map afterwards regardless of
  /// id_type, so ciphertext never reaches a response.
  Future<Map<String, dynamic>> _withDecryptedTin(
    Map<String, dynamic> row,
  ) async {
    if (row['id_type'] == 'tin') {
      row['national_id'] = await _pii.tryDecrypt(row['nat_id_enc'] as String?);
    }
    row.remove('nat_id_enc');
    return row;
  }

  Future<List<Map<String, dynamic>>> _withDecryptedTinList(
    List<Map<String, dynamic>> rows,
  ) =>
      Future.wait(rows.map(_withDecryptedTin));

  /// Fetches + decrypts email_enc (the only storage for email — there is no
  /// plaintext column, unlike phone/national_id) in a separate query rather
  /// than adding it to [_selectFields], so findAll/findSubPatients/
  /// findByPatientCode — none of which display email — never carry raw
  /// ciphertext through to a response. Only [findById] calls this; it's the
  /// single-record lookup behind GET /v1/patient/me and the self-service
  /// profile update below.
  Future<Map<String, dynamic>> _withDecryptedEmail(
    Map<String, dynamic> row,
  ) async {
    final id = row['id'] as String;
    final result = await _pool.execute(
      "SELECT email_enc FROM patients WHERE patient_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    final emailEnc =
        result.rows.isEmpty ? null : result.rows.first.assoc()['email_enc'];
    row['email'] = await _pii.tryDecrypt(emailEnc) ?? '';
    return row;
  }

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

    return (await _withDecryptedTinList(result.rows.map(_rowToMap).toList()), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      "$_selectFields WHERE patient_id = UNHEX(REPLACE(:id, '-', '')) "
      'AND deleted_at IS NULL LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _withDecryptedEmail(
      await _withDecryptedTin(_rowToMap(result.rows.first)),
    );
  }

  Future<Map<String, dynamic>?> findByPatientCode(String code) async {
    final result = await _pool.execute(
      '$_selectFields WHERE patient_code = :code AND deleted_at IS NULL LIMIT 1',
      {'code': code},
    );
    if (result.rows.isEmpty) return null;
    return _withDecryptedTin(_rowToMap(result.rows.first));
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
    return _withDecryptedTinList(result.rows.map(_rowToMap).toList());
  }

  // ── Create ─────────────────────────────────────────────────────────────────

  /// Creates a patient record.
  ///
  /// Pass [walletId] for primary accounts — a wallet row is created atomically.
  /// Omit [walletId] for sub-patients (beneficiaries) — they share the primary
  /// account's wallet and do NOT get their own.
  /// Generates the next LC-XXX code. Must be called on the same connection
  /// as the patient INSERT it backs, inside one transaction — MySQL's
  /// AUTO_INCREMENT on patient_code_seq is already a safe, DB-level atomic
  /// counter under concurrent callers, so no application-level locking is
  /// needed here. If the enclosing transaction rolls back, the burned
  /// sequence number is an accepted, ordinary AUTO_INCREMENT gap.
  Future<String> _nextPatientCode(MySQLConnection conn) async {
    await conn.execute('INSERT INTO patient_code_seq VALUES (NULL)', {});
    final result = await conn.execute('SELECT LAST_INSERT_ID() AS seq', {});
    final seq = int.parse(result.rows.first.assoc()['seq'] ?? '0');
    return 'LC-${seq.toString().padLeft(3, '0')}';
  }

  Future<Map<String, dynamic>> create({
    required String id,
    required String fullName,
    required String createdBy,
    String? walletId,
    String? phone,
    String? nationalId,
    String accountType = 'individual',
    String? primaryAccountId,
    String? relationship,
    bool isMinor = false,
    String idType = 'national_id',
    // Non-null and > 0 only when onboarding a pre-existing client with a
    // starting balance — recorded as an 'opening_balance' ledger entry,
    // never a raw balance overwrite. Caller (PatientService) is
    // responsible for admin-gating this before it reaches here.
    double? openingBalanceShillings,
    // Server-computed override for callers with their own scheme (e.g.
    // sub-patients: {primaryCode}-{suffix}) — never client-suppliable.
    // Independent (non-dependent) patients always get the LC-XXX sequence.
    String? patientCodeOverride,
  }) async {
    // Encrypted alongside plaintext (dual-write) — see PiiEncryptionService.
    // Computed before the transaction since it's just crypto, no DB access.
    final phoneEnc = phone != null ? await _pii.encrypt(phone) : null;
    final nationalIdEnc =
        nationalId != null ? await _pii.encrypt(nationalId) : null;

    // TIN is encrypted-only, unlike national_id's plaintext+encrypted dual
    // write above — nat_id_enc is never decrypted on any other id_type's
    // read path today (see _selectFields), so a plaintext TIN column value
    // would be a permanent, pointless exposure. If encryption isn't
    // configured, fail loudly instead of silently discarding the TIN the
    // way the plaintext fallback would otherwise mask.
    final isTin = idType == 'tin';
    if (isTin && nationalId != null && nationalIdEnc == null) {
      throw ApiError.validationError(
        'TIN cannot be saved: PII encryption is not configured on this server.',
      );
    }
    final nationalIdToStore = isTin ? null : nationalId;

    // Patient + wallet are atomic; audit is best-effort outside the transaction.
    try {
      await _pool.transactional((conn) async {
        final patientCode =
            patientCodeOverride ?? await _nextPatientCode(conn);

        await _insertPatientRow(
          conn,
          id: id,
          patientCode: patientCode,
          fullName: fullName,
          phone: phone,
          phoneEnc: phoneEnc,
          nationalId: nationalIdToStore,
          nationalIdEnc: nationalIdEnc,
          accountType: accountType,
          primaryAccountId: primaryAccountId,
          relationship: relationship,
          isMinor: isMinor,
          idType: idType,
        );

        // A beneficiary is being created — record the relationship in
        // beneficiary_account_links (the source of truth for roster
        // membership going forward), alongside the denormalized
        // primary_account_id already set on the row above.
        if (primaryAccountId != null) {
          await conn.execute(
            'INSERT INTO beneficiary_account_links '
            '(link_id, beneficiary_patient_id, primary_account_id, relationship, linked_by) '
            "VALUES (${uuidParam('linkId')}, ${uuidParam('id')}, "
            "${uuidParam('primaryAccountId')}, :relationship, ${uuidParam('createdBy')})",
            {
              'linkId': generateUuid(),
              'id': id,
              'primaryAccountId': primaryAccountId,
              'relationship': relationship,
              'createdBy': createdBy,
            },
          );
        }

        if (walletId != null) {
          await conn.execute(
            'INSERT INTO wallets (wallet_id, primary_patient_id, balance_shillings, status) '
            "VALUES (UNHEX(REPLACE(:walletId, '-', '')), UNHEX(REPLACE(:patientId, '-', '')), 0, 'ACTIVE')",
            {'walletId': walletId, 'patientId': id},
          );

          if (openingBalanceShillings != null && openingBalanceShillings > 0) {
            await _walletRepo.appendLedgerEntry(
              conn: conn,
              entryId: generateUuid(),
              walletId: walletId,
              transactionType: 'opening_balance',
              amount: openingBalanceShillings,
              initiatedBy: createdBy,
            );
          }
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
        '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:userId, '-', '')), "
        "UNHEX(REPLACE(:userId, '-', '')), "
        "  'create_patient', 'patient', '', "
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

  /// The raw INSERT behind both [create] (wraps it in its own transaction)
  /// and [bulkCreateSubPatients] (calls it once per row inside ONE shared
  /// transaction) — factored out so a roster import can commit every row
  /// atomically instead of one transaction per row.
  Future<void> _insertPatientRow(
    MySQLConnection conn, {
    required String id,
    required String patientCode,
    required String fullName,
    String? phone,
    String? phoneEnc,
    String? nationalId,
    String? nationalIdEnc,
    required String accountType,
    String? primaryAccountId,
    String? costCentreId,
    String? relationship,
    bool isMinor = false,
    String idType = 'national_id',
  }) async {
    final primaryIdHex = primaryAccountId?.replaceAll('-', '');
    final primaryIdExpr = primaryIdHex != null ? "UNHEX('$primaryIdHex')" : 'NULL';
    final costCentreIdHex = costCentreId?.replaceAll('-', '');
    final costCentreIdExpr = costCentreIdHex != null ? "UNHEX('$costCentreIdHex')" : 'NULL';

    await conn.execute(
      'INSERT INTO patients '
      '(patient_id, patient_code, full_name, phone_e164, phone_enc, '
      ' national_id, nat_id_enc, account_type, primary_account_id, cost_centre_id, relationship, is_minor, id_type) '
      "VALUES (UNHEX(REPLACE(:id, '-', '')), :patientCode, :fullName, "
      ':phone, :phoneEnc, :nationalId, :nationalIdEnc, :accountType, '
      '$primaryIdExpr, $costCentreIdExpr, :relationship, :isMinor, :idType)',
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
        'isMinor': isMinor ? 1 : 0,
        'idType': idType,
      },
    );
  }

  /// Global (non-deleted) phone uniqueness check — mirrors the DB's own
  /// idx_patients_phone_uniq constraint (migration 034: a generated column
  /// that's NULL for deleted rows, so only live rows collide).
  Future<bool> phoneExists(String phone) async {
    final result = await _pool.execute(
      'SELECT 1 FROM patients WHERE phone_e164 = :phone AND deleted_at IS NULL LIMIT 1',
      {'phone': phone},
    );
    return result.rows.isNotEmpty;
  }

  /// All-or-nothing roster import (Module 1) — every row is inserted inside
  /// ONE transaction, so a failure partway through rolls back every row
  /// already inserted in this call. Rows are expected to have already
  /// passed PatientService.bulkImportRoster's structural + uniqueness
  /// validation; this method trusts that and only guards against a DB-level
  /// race (e.g. the same phone number registered by a concurrent request
  /// between validation and this call).
  Future<List<Map<String, dynamic>>> bulkCreateSubPatients({
    required String primaryAccountId,
    required List<Map<String, dynamic>> rows,
    required String createdBy,
  }) async {
    final primary = await findById(primaryAccountId);
    if (primary == null) throw ApiError.notFound('Patient not found');
    final primaryCode = primary['patient_code'] as String? ?? '';

    // PII encryption is pure crypto, no DB access — done up front for every
    // row so the transaction below only does DB work.
    final prepared = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = generateUuid();
      final suffix = id.replaceAll('-', '').substring(0, 4).toUpperCase();
      final autoCode = primaryCode.isNotEmpty ? '$primaryCode-$suffix' : 'SUB-$suffix';
      final phone = row['phone'] as String?;
      final idValue = row['id_value'] as String?;
      prepared.add({
        'id': id,
        'patientCode': autoCode,
        'fullName': row['full_name'] as String,
        'phone': phone,
        'phoneEnc': phone != null ? await _pii.encrypt(phone) : null,
        'nationalId': idValue,
        'nationalIdEnc': idValue != null ? await _pii.encrypt(idValue) : null,
        'relationship': row['relationship'] as String? ?? 'Relative',
        'isMinor': row['is_minor'] == true,
        'idType': row['id_type'] as String? ?? 'national_id',
        'costCentreId': row['cost_centre_id'] as String?,
      });
    }

    try {
      await _pool.transactional((conn) async {
        for (final p in prepared) {
          await _insertPatientRow(
            conn,
            id: p['id'] as String,
            patientCode: p['patientCode'] as String,
            fullName: p['fullName'] as String,
            phone: p['phone'] as String?,
            phoneEnc: p['phoneEnc'] as String?,
            nationalId: p['nationalId'] as String?,
            nationalIdEnc: p['nationalIdEnc'] as String?,
            accountType: 'dependent',
            primaryAccountId: primaryAccountId,
            costCentreId: p['costCentreId'] as String?,
            relationship: p['relationship'] as String?,
            isMinor: p['isMinor'] as bool,
            idType: p['idType'] as String,
          );

          final costCentreId = p['costCentreId'] as String?;
          await conn.execute(
            'INSERT INTO beneficiary_account_links '
            '(link_id, beneficiary_patient_id, primary_account_id, relationship, cost_centre_id, linked_by) '
            "VALUES (${uuidParam('linkId')}, ${uuidParam('id')}, "
            "${uuidParam('primaryAccountId')}, :relationship, "
            "${costCentreId != null ? uuidParam('costCentreId') : 'NULL'}, ${uuidParam('createdBy')})",
            {
              'linkId': generateUuid(),
              'id': p['id'] as String,
              'primaryAccountId': primaryAccountId,
              'relationship': p['relationship'] as String?,
              if (costCentreId != null) 'costCentreId': costCentreId,
              'createdBy': createdBy,
            },
          );
        }
        await writeAudit(
          conn: conn,
          actorId: createdBy,
          action: 'BULK_IMPORT_ROSTER',
          targetType: 'patient',
          targetIdUuid: primaryAccountId,
          after: {'row_count': prepared.length},
        );
      });
    } catch (e) {
      if (e.toString().contains('1062')) {
        throw ApiError.conflict(
          'One or more phone numbers in this roster are already registered',
        );
      }
      rethrow;
    }

    final created = <Map<String, dynamic>>[];
    for (final p in prepared) {
      final row = await findById(p['id'] as String);
      if (row != null) created.add(row);
    }
    return created;
  }

  // ── Corporate self-service roster CSV import ─────────────────────────────

  /// Decrypts and returns every currently-live national ID already on file
  /// for this corporate account's own beneficiaries — bounded to one
  /// account's roster, not a global scan. nat_id_enc is a randomized cipher
  /// (AES-GCM, random IV per call), so it can never be looked up by
  /// equality; this is the only way to check "does this ID already exist
  /// under this account" without a schema change (a blind-index column
  /// would be more efficient at large scale — not built here since nothing
  /// asked for a schema change and today's roster sizes don't need it).
  Future<Set<String>> listOwnNationalIds(String primaryAccountId) async {
    final result = await _pool.execute(
      "SELECT nat_id_enc FROM patients "
      "WHERE primary_account_id = UNHEX(REPLACE(:id, '-', '')) "
      'AND deleted_at IS NULL AND nat_id_enc IS NOT NULL',
      {'id': primaryAccountId},
    );
    final ids = <String>{};
    for (final row in result.rows) {
      final plain = await _pii.tryDecrypt(row.assoc()['nat_id_enc']);
      if (plain != null) ids.add(plain);
    }
    return ids;
  }

  /// Partial-success insert for the corporate self-service CSV roster
  /// import — every row that already passed PatientService
  /// .bulkImportOwnRoster's validation gets its OWN transaction, so a late
  /// DB-level failure on one row (e.g. a genuine race between two
  /// concurrent uploads) never rolls back rows that already succeeded.
  /// Deliberately NOT [bulkCreateSubPatients]'s one-shared-transaction
  /// pattern above, which is correct for the admin-only all-or-nothing
  /// import but would defeat partial-success here.
  ///
  /// [rows] entries: {row_number, full_name, phone?, national_id?} — every
  /// row is inserted with relationship='employee', accountType='dependent'.
  /// Returns one outcome per row: {row, imported: true} or
  /// {row, imported: false, errors: [...]}.
  Future<List<Map<String, dynamic>>> insertRosterRowsPartial({
    required String primaryAccountId,
    required List<Map<String, dynamic>> rows,
    required String createdBy,
  }) async {
    final primary = await findById(primaryAccountId);
    if (primary == null) throw ApiError.notFound('Patient not found');
    final primaryCode = primary['patient_code'] as String? ?? '';

    final outcomes = <Map<String, dynamic>>[];
    var successCount = 0;

    for (final row in rows) {
      final rowNumber = row['row_number'] as int;
      final id = generateUuid();
      final suffix = id.replaceAll('-', '').substring(0, 4).toUpperCase();
      final autoCode = primaryCode.isNotEmpty ? '$primaryCode-$suffix' : 'SUB-$suffix';
      final phone = row['phone'] as String?;
      final nationalId = row['national_id'] as String?;

      // Pure crypto, no DB access — done before this row's own transaction,
      // matching create()/bulkCreateSubPatients' existing convention.
      final phoneEnc = phone != null ? await _pii.encrypt(phone) : null;
      final nationalIdEnc = nationalId != null ? await _pii.encrypt(nationalId) : null;

      try {
        await _pool.transactional((conn) async {
          await _insertPatientRow(
            conn,
            id: id,
            patientCode: autoCode,
            fullName: row['full_name'] as String,
            phone: phone,
            phoneEnc: phoneEnc,
            nationalId: nationalId,
            nationalIdEnc: nationalIdEnc,
            accountType: 'dependent',
            primaryAccountId: primaryAccountId,
            relationship: 'employee',
            idType: 'national_id',
          );
        });
        successCount++;
        outcomes.add({'row': rowNumber, 'imported': true});
      } catch (e) {
        final message = e.toString().contains('1062')
            ? 'A record with this phone number or national ID was just created by another request'
            : 'Failed to save this row';
        outcomes.add({'row': rowNumber, 'imported': false, 'errors': [message]});
      }
    }

    // One summary audit entry for the whole batch, written after the loop
    // (not per-row) — matches bulkCreateSubPatients' one-entry-per-batch
    // convention above.
    try {
      await _pool.transactional((conn) async {
        await writeAudit(
          conn: conn,
          actorId: createdBy,
          action: 'BULK_IMPORT_OWN_ROSTER',
          targetType: 'patient',
          targetIdUuid: primaryAccountId,
          after: {
            'row_count': rows.length,
            'success_count': successCount,
            'failed_count': rows.length - successCount,
          },
        );
      });
    } catch (_) {
      // Audit failure is non-fatal — matches create()'s existing convention.
    }

    return outcomes;
  }

  // ── Cost centres (corporate accounts) ────────────────────────────────────

  static final _costCentreSelect =
      'SELECT ${uuidSelect('cost_centre_id', 'id')}, '
      'name, is_active, created_at '
      'FROM cost_centres';

  Future<List<Map<String, dynamic>>> listCostCentres(
    String corporateAccountId,
  ) async {
    final result = await _pool.execute(
      '$_costCentreSelect '
      "WHERE corporate_account_id = UNHEX(REPLACE(:corpId, '-', '')) AND is_active = 1 "
      'ORDER BY name',
      {'corpId': corporateAccountId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  Future<Map<String, dynamic>?> findCostCentreById(String id) async {
    final result = await _pool.execute(
      "$_costCentreSelect WHERE ${uuidWhere('cost_centre_id', 'id')} LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  /// True only when [costCentreId] both exists and belongs to
  /// [corporateAccountId] — used to validate a roster row's cost_centre_id
  /// without leaking whether a cost centre exists under a DIFFERENT
  /// corporate account.
  Future<bool> costCentreBelongsTo(
    String costCentreId,
    String corporateAccountId,
  ) async {
    final result = await _pool.execute(
      'SELECT 1 FROM cost_centres '
      "WHERE ${uuidWhere('cost_centre_id', 'id')} "
      "AND corporate_account_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND is_active = 1 LIMIT 1',
      {'id': costCentreId, 'corpId': corporateAccountId},
    );
    return result.rows.isNotEmpty;
  }

  Future<Map<String, dynamic>> createCostCentre({
    required String corporateAccountId,
    required String name,
    required String createdBy,
  }) async {
    final id = generateUuid();
    try {
      await _pool.transactional((conn) async {
        await conn.execute(
          'INSERT INTO cost_centres (cost_centre_id, corporate_account_id, name) '
          "VALUES (${uuidParam('id')}, ${uuidParam('corpId')}, :name)",
          {'id': id, 'corpId': corporateAccountId, 'name': name},
        );
        await writeAudit(
          conn: conn,
          actorId: createdBy,
          action: 'CREATE_COST_CENTRE',
          targetType: 'cost_centre',
          targetIdUuid: id,
          after: {'name': name, 'corporate_account_id': corporateAccountId},
        );
      });
    } catch (e) {
      if (e.toString().contains('1062')) {
        throw ApiError.conflict('A cost centre with this name already exists');
      }
      rethrow;
    }
    return (await findCostCentreById(id))!;
  }

  Future<Map<String, dynamic>?> renameCostCentre(
    String id,
    String name, {
    required String actorId,
  }) async {
    try {
      await _pool.transactional((conn) async {
        await conn.execute(
          'UPDATE cost_centres SET name = :name '
          "WHERE ${uuidWhere('cost_centre_id', 'id')}",
          {'id': id, 'name': name},
        );
        await writeAudit(
          conn: conn,
          actorId: actorId,
          action: 'RENAME_COST_CENTRE',
          targetType: 'cost_centre',
          targetIdUuid: id,
          after: {'name': name},
        );
      });
    } catch (e) {
      if (e.toString().contains('1062')) {
        throw ApiError.conflict('A cost centre with this name already exists');
      }
      rethrow;
    }
    return findCostCentreById(id);
  }

  Future<bool> retireCostCentre(String id, {required String actorId}) async {
    var affected = 0;
    await _pool.transactional((conn) async {
      final result = await conn.execute(
        'UPDATE cost_centres SET is_active = 0 '
        "WHERE ${uuidWhere('cost_centre_id', 'id')} AND is_active = 1",
        {'id': id},
      );
      affected = result.affectedRows.toInt();
      if (affected > 0) {
        await writeAudit(
          conn: conn,
          actorId: actorId,
          action: 'RETIRE_COST_CENTRE',
          targetType: 'cost_centre',
          targetIdUuid: id,
        );
      }
    });
    return affected > 0;
  }

  /// Admin-set ceiling — null clears it. Only meaningful on a corporate
  /// primary account; PatientService enforces that before calling this.
  Future<Map<String, dynamic>> setAllocatedBudget(
    String corporateAccountId,
    double? budgetShillings, {
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE patients SET allocated_budget_shillings = :budget '
        "WHERE ${uuidWhere('patient_id', 'id')}",
        {'id': corporateAccountId, 'budget': budgetShillings},
      );
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'SET_ALLOCATED_BUDGET',
        targetType: 'patient',
        targetIdUuid: corporateAccountId,
        after: {'allocated_budget_shillings': budgetShillings},
      );
    });
    return (await findById(corporateAccountId))!;
  }

  // ── Update ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
    String updatedBy,
  ) async {
    if (fields.isEmpty) return findById(id);

    // patient_code is deliberately excluded — server-generated at create
    // time and immutable after that, never editable via update.
    final allowed = <String>[
      'full_name',
      'phone_e164',
      'national_id',
      'account_type',
      'is_active',
      'relationship',
      'is_minor',
      'id_type',
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
      // TIN is encrypted-only — no plaintext national_id column write, and
      // encryption must actually succeed (see create()'s matching check).
      if (fields['id_type'] == 'tin') {
        if (enc == null) {
          throw ApiError.validationError(
            'TIN cannot be saved: PII encryption is not configured on this server.',
          );
        }
        params['national_id'] = null;
        setClauseParts.add('nat_id_enc = :nationalIdEnc');
        params['nationalIdEnc'] = enc;
      } else if (enc != null) {
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

  /// Patient self-service profile update — deliberately NOT a wrapper around
  /// [update] above, which also accepts account_type/is_active/relationship/
  /// is_minor. A patient must never be able to set those on themselves; this
  /// method only ever touches full_name/phone_e164/email, and skips any
  /// field left null (an omitted field is not the same as clearing it).
  /// email has no plaintext column — it's encrypt-only, matching the schema
  /// (see _withDecryptedEmail's comment on why the read side is separate).
  Future<Map<String, dynamic>?> updateOwnProfile(
    String id, {
    String? fullName,
    String? phone,
    String? email,
  }) async {
    final setClauseParts = <String>[];
    final params = <String, dynamic>{'id': id};

    if (fullName != null && fullName.isNotEmpty) {
      setClauseParts.add('full_name = :fullName');
      params['fullName'] = fullName;
    }
    if (phone != null && phone.isNotEmpty) {
      setClauseParts.add('phone_e164 = :phone');
      params['phone'] = phone;
      final enc = await _pii.encrypt(phone);
      if (enc != null) {
        setClauseParts.add('phone_enc = :phoneEnc');
        params['phoneEnc'] = enc;
      }
    }
    if (email != null && email.isNotEmpty) {
      final enc = await _pii.encrypt(email);
      if (enc != null) {
        setClauseParts.add('email_enc = :emailEnc');
        params['emailEnc'] = enc;
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

  /// Removes a beneficiary from a primary account's roster. Unlike the old
  /// softDeleteSubPatient (retired — used to set patients.deleted_at on the
  /// beneficiary's own row), this never touches the beneficiary's clinical/
  /// financial identity at all: encounters, encounter_services,
  /// encounter_medications, and wallet_ledger all still reference
  /// patient_id, untouched. Only the relationship — beneficiary_account_links
  /// — is hard-deleted; no deleted_at/is_active flag is ever set on it or on
  /// the beneficiary's patients row. patients.primary_account_id is cleared
  /// as a denormalized cache update, not the removal itself.
  Future<void> unlinkBeneficiary({
    required String beneficiaryId,
    required String primaryAccountId,
    required String unlinkedBy,
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'DELETE FROM beneficiary_account_links '
        "WHERE ${uuidWhere('beneficiary_patient_id', 'beneficiaryId')} "
        "AND ${uuidWhere('primary_account_id', 'primaryAccountId')}",
        {'beneficiaryId': beneficiaryId, 'primaryAccountId': primaryAccountId},
      );
      await conn.execute(
        'UPDATE patients SET primary_account_id = NULL '
        "WHERE ${uuidWhere('patient_id', 'beneficiaryId')}",
        {'beneficiaryId': beneficiaryId},
      );
      await writeAudit(
        conn: conn,
        actorId: unlinkedBy,
        action: 'UNLINK_BENEFICIARY',
        targetType: 'patient',
        targetIdUuid: beneficiaryId,
        before: {'primary_account_id': primaryAccountId},
        after: {'primary_account_id': null},
      );
    });
  }

  // ── Beneficiary login access ────────────────────────────────────────────────

  /// Sets the beneficiary's login-access journey state. Deliberately NOT
  /// exposed through the generic update()/allowed list — this must only be
  /// driven by PatientCredentialsService/PatientService transitions, never
  /// by a client PATCHing /v1/patients/<id> or /v1/patient/beneficiaries/<id>.
  Future<void> setLoginAccessStatus(String patientId, String status) async {
    await _pool.execute(
      "UPDATE patients SET login_access_status = :status "
      "WHERE ${uuidWhere('patient_id', 'id')}",
      {'id': patientId, 'status': status},
    );
  }

  /// Inserts a login-access-request row, flips the beneficiary to 'pending',
  /// and writes the audit entry — all in one transaction so the three can
  /// never diverge.
  Future<Map<String, dynamic>> createLoginAccessRequest({
    required String beneficiaryId,
    required String primaryId,
  }) async {
    final requestId = generateUuid();
    await _pool.transactional((conn) async {
      await conn.execute(
        'INSERT INTO beneficiary_login_requests '
        '(request_id, beneficiary_id, primary_id, status) '
        "VALUES (${uuidParam('requestId')}, ${uuidParam('beneficiaryId')}, "
        "${uuidParam('primaryId')}, 'pending')",
        {
          'requestId': requestId,
          'beneficiaryId': beneficiaryId,
          'primaryId': primaryId,
        },
      );
      await conn.execute(
        "UPDATE patients SET login_access_status = 'pending' "
        "WHERE ${uuidWhere('patient_id', 'beneficiaryId')}",
        {'beneficiaryId': beneficiaryId},
      );
      await writeAudit(
        conn: conn,
        actorId: primaryId,
        action: 'BENEFICIARY_LOGIN_ACCESS_REQUEST',
        targetType: 'patient',
        targetIdUuid: beneficiaryId,
      );
    });
    return {
      'request_id': requestId,
      'beneficiary_id': beneficiaryId,
      'primary_id': primaryId,
      'status': 'pending',
    };
  }

  Future<(List<Map<String, dynamic>>, int)> findLoginAccessRequests({
    int limit = 20,
    int offset = 0,
    String? status,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    if (status != null && status.isNotEmpty) {
      conditions.add('r.status = :status');
      params['status'] = status;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM beneficiary_login_requests r $where',
      status != null ? {'status': status} : {},
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT ${uuidSelect('r.request_id', 'request_id')}, '
      '${uuidSelect('r.beneficiary_id', 'beneficiary_id')}, '
      '${uuidSelect('r.primary_id', 'primary_id')}, '
      'r.status, r.requested_at, r.resolved_at, '
      'b.full_name AS beneficiary_name, b.phone_e164 AS beneficiary_phone, '
      'b.patient_code AS beneficiary_code, b.is_minor AS beneficiary_is_minor, '
      'p.full_name AS primary_name, p.patient_code AS primary_code '
      'FROM beneficiary_login_requests r '
      'LEFT JOIN patients b ON b.patient_id = r.beneficiary_id '
      'LEFT JOIN patients p ON p.patient_id = r.primary_id '
      '$where '
      'ORDER BY r.requested_at DESC LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  /// Auto-resolves the most recent open request for [beneficiaryId] to
  /// 'approved' once an admin has actually generated credentials — called
  /// from PatientCredentialsService.generate() so a queue item never lingers
  /// "pending" after credentials already exist. No-op if there is no
  /// pending request (a beneficiary can get credentials without ever having
  /// gone through the request flow).
  Future<void> autoApproveLoginAccessRequest(String beneficiaryId) async {
    await _pool.execute(
      "UPDATE beneficiary_login_requests "
      "SET status = 'approved', resolved_at = NOW() "
      "WHERE ${uuidWhere('beneficiary_id', 'beneficiaryId')} AND status = 'pending' "
      "ORDER BY requested_at DESC LIMIT 1",
      {'beneficiaryId': beneficiaryId},
    );
  }

  /// Rejects the given request, resets its beneficiary back to 'no_login',
  /// and writes the audit entry in one transaction. Throws ApiError.notFound
  /// if the request doesn't exist or is no longer pending.
  Future<void> rejectLoginAccessRequest({
    required String requestId,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      final result = await conn.execute(
        "SELECT ${uuidSelect('beneficiary_id', 'beneficiary_id')} "
        "FROM beneficiary_login_requests "
        "WHERE ${uuidWhere('request_id', 'requestId')} AND status = 'pending' LIMIT 1",
        {'requestId': requestId},
      );
      if (result.rows.isEmpty) {
        throw ApiError.notFound('Login-access request not found or already resolved');
      }
      final beneficiaryId = result.rows.first.assoc()['beneficiary_id']!;

      await conn.execute(
        "UPDATE beneficiary_login_requests SET status = 'rejected', resolved_at = NOW(), "
        "resolved_by = ${uuidParam('actorId')} "
        "WHERE ${uuidWhere('request_id', 'requestId')}",
        {'requestId': requestId, 'actorId': actorId},
      );
      await conn.execute(
        "UPDATE patients SET login_access_status = 'no_login' "
        "WHERE ${uuidWhere('patient_id', 'beneficiaryId')}",
        {'beneficiaryId': beneficiaryId},
      );
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'BENEFICIARY_LOGIN_ACCESS_REJECT',
        targetType: 'patient',
        targetIdUuid: beneficiaryId,
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

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
