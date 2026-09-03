import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class WalletRepository {
  final MySQLConnectionPool _pool;

  WalletRepository(this._pool);

  /// Exposed so external services (e.g. DepositService) can pass the pool
  /// directly to [appendLedgerEntry] without needing a transaction wrapper.
  MySQLConnectionPool get pool => _pool;

  // ── DB column reality ─────────────────────────────────────────────────────
  // wallets:      wallet_id (PK), primary_patient_id, balance_minor,
  //               balance_shillings, status, created_at, last_activity_at
  // wallet_ledger: ledger_id (PK), wallet_id, encounter_id (migration 035),
  //               type, status, amount_shillings, failure_reason, created_at
  // ─────────────────────────────────────────────────────────────────────────

  // Wallet SELECT — aliases wallet_id→id, patient_id coalesced from both
  // primary_patient_id and patient_id columns (schema has both).
  // account_type is joined from patients (via the same coalesced owner id)
  // so WalletService can scope admin balance adjustments to corporate/
  // remittance accounts without a second query.
  static const _walletSelect =
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(w.wallet_id),1,8),'-',SUBSTR(HEX(w.wallet_id),9,4),'-',"
      "SUBSTR(HEX(w.wallet_id),13,4),'-',SUBSTR(HEX(w.wallet_id),17,4),'-',"
      "SUBSTR(HEX(w.wallet_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(COALESCE(w.primary_patient_id, w.patient_id)),1,8),'-',"
      "SUBSTR(HEX(COALESCE(w.primary_patient_id, w.patient_id)),9,4),'-',"
      "SUBSTR(HEX(COALESCE(w.primary_patient_id, w.patient_id)),13,4),'-',"
      "SUBSTR(HEX(COALESCE(w.primary_patient_id, w.patient_id)),17,4),'-',"
      "SUBSTR(HEX(COALESCE(w.primary_patient_id, w.patient_id)),21))) AS patient_id, "
      'w.balance_shillings AS balance, w.status, w.created_at, '
      'w.last_activity_at AS updated_at, p.account_type '
      'FROM wallets w '
      'LEFT JOIN patients p ON p.patient_id = COALESCE(w.primary_patient_id, w.patient_id)';

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
  }) async {
    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM wallets',
      {},
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_walletSelect ORDER BY w.created_at DESC LIMIT :limit OFFSET :offset',
      {'limit': limit, 'offset': offset},
    );
    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      "$_walletSelect WHERE w.wallet_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  /// Resolves the wallet for a patient id. A beneficiary has no wallet row
  /// of their own (createSubPatient always passes walletId: null — they
  /// share the primary account's wallet), so the lookup first resolves the
  /// requesting patient's effective owner via patients.primary_account_id
  /// (falling back to their own id when they ARE the primary), then matches
  /// that against the wallet's owner columns.
  Future<Map<String, dynamic>?> findByPatientId(String patientId) async {
    final result = await _pool.execute(
      '$_walletSelect '
      "WHERE COALESCE(w.primary_patient_id, w.patient_id) = COALESCE("
      "  (SELECT primary_account_id FROM patients WHERE patient_id = UNHEX(REPLACE(:patientId, '-', ''))), "
      "  UNHEX(REPLACE(:patientId, '-', ''))"
      ') '
      'LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  // ── Ledger ────────────────────────────────────────────────────────────────

  // encounter_id is nullable (most ledger rows — deposits, standalone
  // checkouts — have none), so the HEX/CONCAT below naturally yields NULL
  // rather than a malformed string when it's absent; no CASE needed.
  static const _ledgerSelect =
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(wl.ledger_id),1,8),'-',SUBSTR(HEX(wl.ledger_id),9,4),'-',"
      "SUBSTR(HEX(wl.ledger_id),13,4),'-',SUBSTR(HEX(wl.ledger_id),17,4),'-',"
      "SUBSTR(HEX(wl.ledger_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(wl.wallet_id),1,8),'-',SUBSTR(HEX(wl.wallet_id),9,4),'-',"
      "SUBSTR(HEX(wl.wallet_id),13,4),'-',SUBSTR(HEX(wl.wallet_id),17,4),'-',"
      "SUBSTR(HEX(wl.wallet_id),21))) AS wallet_id, "
      "LOWER(CONCAT(SUBSTR(HEX(wl.initiated_by),1,8),'-',SUBSTR(HEX(wl.initiated_by),9,4),'-',"
      "SUBSTR(HEX(wl.initiated_by),13,4),'-',SUBSTR(HEX(wl.initiated_by),17,4),'-',"
      "SUBSTR(HEX(wl.initiated_by),21))) AS initiated_by, "
      "LOWER(CONCAT(SUBSTR(HEX(wl.encounter_id),1,8),'-',SUBSTR(HEX(wl.encounter_id),9,4),'-',"
      "SUBSTR(HEX(wl.encounter_id),13,4),'-',SUBSTR(HEX(wl.encounter_id),17,4),'-',"
      "SUBSTR(HEX(wl.encounter_id),21))) AS encounter_id, "
      'wl.type, wl.amount_shillings, wl.status, wl.failure_reason, wl.reason, wl.created_at, '
      // Deliberately NOT selecting e.reason here — that's the beneficiary-
      // owned, redaction-gated field (see encounter_repository._redact).
      // This endpoint has no asPrimaryView/caller-role plumbing, so pulling
      // reason through unredacted would leak a hidden reason via Activity
      // even when /patient/visits correctly withholds it. service_type is
      // a coarse category (e.g. "General", "Lab"), not the clinical note —
      // safe to always show.
      'e.reference_number AS encounter_reference, e.service_type AS encounter_service_type '
      'FROM wallet_ledger wl '
      'LEFT JOIN encounters e ON e.encounter_id = wl.encounter_id';

  /// Returns all ledger entries across all wallets, most recent first.
  Future<(List<Map<String, dynamic>>, int)> findAllLedger({
    int limit = 50,
    int offset = 0,
    String? type,
    String? from,
    String? to,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    if (type != null) {
      conditions.add('wl.type = :type');
      params['type'] = type;
    }
    if (from != null) {
      conditions.add('wl.created_at >= :from');
      params['from'] = from;
    }
    if (to != null) {
      conditions.add('wl.created_at <= :to');
      params['to'] = to;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM wallet_ledger wl $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_ledgerSelect $where ORDER BY wl.created_at DESC LIMIT :limit OFFSET :offset',
      params,
    );
    return (result.rows.map(_rowToMap).toList(), total);
  }

  /// [initiatedByFilter], when set, restricts results to entries attributed
  /// to that patient — used to scope a beneficiary's transaction view to
  /// only what they personally initiated. Omit it for the primary account
  /// holder's unfiltered, full-wallet view.
  Future<(List<Map<String, dynamic>>, int)> getLedger(
    String walletId, {
    int limit = 20,
    int offset = 0,
    String? initiatedByFilter,
  }) async {
    final where = "WHERE wl.wallet_id = UNHEX(REPLACE(:walletId, '-', '')) "
        "${initiatedByFilter != null ? "AND wl.initiated_by = UNHEX(REPLACE(:initiatedBy, '-', ''))" : ''}";
    final params = <String, dynamic>{
      'walletId': walletId,
      if (initiatedByFilter != null) 'initiatedBy': initiatedByFilter,
    };

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM wallet_ledger wl $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_ledgerSelect $where ORDER BY wl.created_at DESC LIMIT :limit OFFSET :offset',
      {...params, 'limit': limit, 'offset': offset},
    );
    return (result.rows.map(_rowToMap).toList(), total);
  }

  /// Full, unpaginated ledger history for a wallet in chronological (ASC)
  /// order — used by the account statement (Module 5), which needs to
  /// reconstruct a running balance across every entry, not a page of them.
  Future<List<Map<String, dynamic>>> getAllLedgerForStatement(
    String walletId,
  ) async {
    final result = await _pool.execute(
      "$_ledgerSelect WHERE wl.wallet_id = UNHEX(REPLACE(:walletId, '-', '')) "
      'ORDER BY wl.created_at ASC',
      {'walletId': walletId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  // ── Internal helper: append a ledger row + update denormalised balance ────
  // Used by both createTransaction (standalone) and encounter_repository
  // (inside its own transaction, via the conn param).
  Future<void> appendLedgerEntry({
    required dynamic conn,
    required String entryId,
    required String walletId,
    required String transactionType,
    required double amount,
    String? initiatedBy,
    String? reason,
  }) async {
    final amountInt = amount.round();
    // Signed delta: positive types add, negative types subtract.
    // 'opening_balance' is written directly by PatientRepository.create()
    // when onboarding a pre-existing client with a non-zero starting
    // balance — never exposed through WalletService.createTransaction's
    // validTypes, so it can't be injected onto an existing wallet later.
    final isCredit = ['deposit', 'refund', 'adjustment', 'opening_balance']
        .contains(transactionType);
    final delta = isCredit ? amountInt : -amountInt;

    await conn.execute(
      'INSERT INTO wallet_ledger (ledger_id, wallet_id, initiated_by, type, amount_shillings, reason) '
      "VALUES (UNHEX(REPLACE(:entryId, '-', '')), "
      "UNHEX(REPLACE(:walletId, '-', '')), "
      "${initiatedBy != null ? "UNHEX(REPLACE(:initiatedBy, '-', ''))" : 'NULL'}, "
      ':type, :amount, :reason)',
      {
        'entryId': entryId,
        'walletId': walletId,
        if (initiatedBy != null) 'initiatedBy': initiatedBy,
        'type': transactionType,
        'amount': amountInt,
        'reason': reason,
      },
    );

    if (isCredit) {
      await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings + :delta, '
        '    last_activity_at = NOW() '
        "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
        {'delta': delta, 'walletId': walletId},
      );
    } else {
      // Atomic balance floor: only apply if the result would be non-negative.
      // This prevents concurrent deductions from racing past the pre-check and
      // driving the balance below zero.
      final result = await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings + :delta, '
        '    last_activity_at = NOW() '
        "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', '')) "
        'AND balance_shillings + :delta >= 0',
        {'delta': delta, 'walletId': walletId},
      );
      if (result.affectedRows.toInt() == 0) {
        throw ApiError.businessRule('Insufficient wallet balance');
      }
    }
  }

  // ── Public transaction (deposit / deduction / etc.) ───────────────────────

  Future<Map<String, dynamic>> createTransaction({
    required String walletId,
    required String transactionType,
    required double amount,
    required String createdBy,
    String? notes,
  }) async {
    final wallet = await findById(walletId);
    if (wallet == null) throw ApiError.notFound('Wallet not found');

    final balance = (wallet['balance'] as num?)?.toDouble() ?? 0;
    if (['deduction', 'debt_created'].contains(transactionType) &&
        balance < amount) {
      throw ApiError.businessRule('Insufficient wallet balance');
    }

    final entryId = generateUuid();

    await _pool.transactional((conn) async {
      await appendLedgerEntry(
        conn: conn,
        entryId: entryId,
        walletId: walletId,
        transactionType: transactionType,
        amount: amount,
        reason: notes,
      );

      await writeAudit(
        conn: conn,
        actorId: createdBy,
        action: 'WALLET_TRANSACTION',
        targetType: 'wallet',
        targetIdUuid: walletId,
        after: {
          'type': transactionType,
          'amount': amount,
          if (notes != null) 'reason': notes,
        },
      );
    });

    // Return the created ledger entry.
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(ledger_id),1,8),'-',SUBSTR(HEX(ledger_id),9,4),'-',"
      "SUBSTR(HEX(ledger_id),13,4),'-',SUBSTR(HEX(ledger_id),17,4),'-',"
      "SUBSTR(HEX(ledger_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(wallet_id),1,8),'-',SUBSTR(HEX(wallet_id),9,4),'-',"
      "SUBSTR(HEX(wallet_id),13,4),'-',SUBSTR(HEX(wallet_id),17,4),'-',"
      "SUBSTR(HEX(wallet_id),21))) AS wallet_id, "
      'type, amount_shillings, status, failure_reason, reason, created_at '
      'FROM wallet_ledger '
      "WHERE ledger_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': entryId},
    );
    return _rowToMap(result.rows.first);
  }

  Future<List<Map<String, dynamic>>> findDependentsByWalletId(
    String walletId,
  ) async {
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(dependent_id),1,8),'-',SUBSTR(HEX(dependent_id),9,4),'-',"
      "SUBSTR(HEX(dependent_id),13,4),'-',SUBSTR(HEX(dependent_id),17,4),'-',"
      "SUBSTR(HEX(dependent_id),21))) AS id, "
      'full_name, phone_number, relationship, national_id, is_active, created_at '
      'FROM dependents '
      "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', '')) AND is_active = 1",
      {'walletId': walletId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
