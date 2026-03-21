import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class WalletRepository {
  final MySQLConnectionPool _pool;

  WalletRepository(this._pool);

  // ── DB column reality ─────────────────────────────────────────────────────
  // wallets:      wallet_id (PK), primary_patient_id, balance_minor,
  //               balance_shillings, status, created_at, last_activity_at
  // wallet_ledger: ledger_id (PK), wallet_id, type, status,
  //               amount_shillings, failure_reason, created_at
  // ─────────────────────────────────────────────────────────────────────────

  // Wallet SELECT — aliases wallet_id→id, patient_id coalesced from both
  // primary_patient_id and patient_id columns (schema has both).
  static const _walletSelect =
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(wallet_id),1,8),'-',SUBSTR(HEX(wallet_id),9,4),'-',"
      "SUBSTR(HEX(wallet_id),13,4),'-',SUBSTR(HEX(wallet_id),17,4),'-',"
      "SUBSTR(HEX(wallet_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(COALESCE(primary_patient_id, patient_id)),1,8),'-',"
      "SUBSTR(HEX(COALESCE(primary_patient_id, patient_id)),9,4),'-',"
      "SUBSTR(HEX(COALESCE(primary_patient_id, patient_id)),13,4),'-',"
      "SUBSTR(HEX(COALESCE(primary_patient_id, patient_id)),17,4),'-',"
      "SUBSTR(HEX(COALESCE(primary_patient_id, patient_id)),21))) AS patient_id, "
      'balance_shillings AS balance, status, created_at, '
      'last_activity_at AS updated_at '
      'FROM wallets';

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
      '$_walletSelect ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      {'limit': limit, 'offset': offset},
    );
    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      "$_walletSelect WHERE wallet_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByPatientId(String patientId) async {
    final result = await _pool.execute(
      "$_walletSelect WHERE primary_patient_id = UNHEX(REPLACE(:patientId, '-', '')) LIMIT 1",
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  // ── Ledger ────────────────────────────────────────────────────────────────

  static const _ledgerSelect =
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(ledger_id),1,8),'-',SUBSTR(HEX(ledger_id),9,4),'-',"
      "SUBSTR(HEX(ledger_id),13,4),'-',SUBSTR(HEX(ledger_id),17,4),'-',"
      "SUBSTR(HEX(ledger_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(wallet_id),1,8),'-',SUBSTR(HEX(wallet_id),9,4),'-',"
      "SUBSTR(HEX(wallet_id),13,4),'-',SUBSTR(HEX(wallet_id),17,4),'-',"
      "SUBSTR(HEX(wallet_id),21))) AS wallet_id, "
      'type, amount_shillings, status, failure_reason, created_at '
      'FROM wallet_ledger';

  /// Returns all ledger entries across all wallets, most recent first.
  Future<(List<Map<String, dynamic>>, int)> findAllLedger({
    int limit = 50,
    int offset = 0,
    String? type,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    if (type != null) {
      conditions.add('type = :type');
      params['type'] = type;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM wallet_ledger $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_ledgerSelect $where ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      params,
    );
    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<(List<Map<String, dynamic>>, int)> getLedger(
    String walletId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final countResult = await _pool.execute(
      "SELECT COUNT(*) as total FROM wallet_ledger "
      "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
      {'walletId': walletId},
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_ledgerSelect '
      "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', '')) "
      'ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      {'walletId': walletId, 'limit': limit, 'offset': offset},
    );
    return (result.rows.map(_rowToMap).toList(), total);
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
  }) async {
    final amountInt = amount.round();
    // Signed delta: positive types add, negative types subtract.
    final isCredit =
        ['deposit', 'refund', 'adjustment'].contains(transactionType);
    final delta = isCredit ? amountInt : -amountInt;

    await conn.execute(
      'INSERT INTO wallet_ledger (ledger_id, wallet_id, type, amount_shillings) '
      "VALUES (UNHEX(REPLACE(:entryId, '-', '')), "
      "UNHEX(REPLACE(:walletId, '-', '')), "
      ':type, :amount)',
      {
        'entryId': entryId,
        'walletId': walletId,
        'type': transactionType,
        'amount': amountInt,
      },
    );

    await conn.execute(
      'UPDATE wallets '
      'SET balance_shillings = balance_shillings + :delta, '
      '    last_activity_at = NOW() '
      "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
      {'delta': delta, 'walletId': walletId},
    );
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
      );

      // Audit log — uses correct schema columns.
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, actor_user_id, action_type, entity_type, entity_id, request_id) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':actionType, :entityType, '
        "UNHEX(REPLACE(:entityId, '-', '')), :requestId)",
        {
          'auditId': generateUuid(),
          'actorId': createdBy,
          'actionType': 'WALLET_TRANSACTION',
          'entityType': 'wallet',
          'entityId': walletId,
          'requestId': generateUuid(),
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
      'type, amount_shillings, status, failure_reason, created_at '
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
