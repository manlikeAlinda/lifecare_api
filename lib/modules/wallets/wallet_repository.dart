import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class WalletRepository {
  final MySQLConnectionPool _pool;

  WalletRepository(this._pool);

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id";
  static const _uuidPatientId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',SUBSTR(HEX(patient_id),21))) AS patient_id";

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
      'SELECT $_uuidId, $_uuidPatientId, '
      '(SELECT COALESCE(SUM(CASE WHEN transaction_type IN (\'deposit\',\'refund\',\'adjustment\') THEN amount '
      'WHEN transaction_type IN (\'deduction\',\'debt_created\') THEN -amount ELSE 0 END), 0) '
      'FROM wallet_ledger WHERE wallet_id = wallets.id) AS balance, '
      'created_at, updated_at '
      'FROM wallets ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      {'limit': limit, 'offset': offset},
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      'SELECT $_uuidId, $_uuidPatientId, '
      '(SELECT COALESCE(SUM(CASE WHEN transaction_type IN (\'deposit\',\'refund\',\'adjustment\') THEN amount '
      'WHEN transaction_type IN (\'deduction\',\'debt_created\') THEN -amount ELSE 0 END), 0) '
      'FROM wallet_ledger WHERE wallet_id = wallets.id) AS balance, '
      'created_at, updated_at '
      'FROM wallets WHERE ${uuidWhere('id', 'id')} LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByPatientId(String patientId) async {
    final result = await _pool.execute(
      'SELECT $_uuidId, $_uuidPatientId, '
      '(SELECT COALESCE(SUM(CASE WHEN transaction_type IN (\'deposit\',\'refund\',\'adjustment\') THEN amount '
      'WHEN transaction_type IN (\'deduction\',\'debt_created\') THEN -amount ELSE 0 END), 0) '
      'FROM wallet_ledger WHERE wallet_id = wallets.id) AS balance, '
      'created_at, updated_at '
      'FROM wallets WHERE ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<(List<Map<String, dynamic>>, int)> getLedger(
    String walletId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM wallet_ledger WHERE ${uuidWhere('wallet_id', 'walletId')}',
      {'walletId': walletId},
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(wallet_id),1,8),'-',SUBSTR(HEX(wallet_id),9,4),'-',SUBSTR(HEX(wallet_id),13,4),'-',SUBSTR(HEX(wallet_id),17,4),'-',SUBSTR(HEX(wallet_id),21))) AS wallet_id, "
      'transaction_type, amount, balance_before, balance_after, '
      'reference_type, notes, created_at '
      'FROM wallet_ledger '
      'WHERE ${uuidWhere('wallet_id', 'walletId')} '
      'ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      {'walletId': walletId, 'limit': limit, 'offset': offset},
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  /// Appends a ledger entry inside the given connection (for use within transactions).
  Future<void> appendLedgerEntry({
    required dynamic conn, // MySQLConnectionPool or transaction connection
    required String entryId,
    required String walletId,
    required String transactionType,
    required double amount,
    required double balanceBefore,
    required String? createdBy,
    String? referenceType,
    String? referenceId,
    String? notes,
  }) async {
    final balanceAfter = _calculateNewBalance(
      balanceBefore,
      transactionType,
      amount,
    );
    await conn.execute(
      'INSERT INTO wallet_ledger '
      '(id, wallet_id, transaction_type, amount, balance_before, balance_after, '
      'reference_type, reference_id, notes, created_by) '
      'VALUES (${uuidParam('id')}, ${uuidParam('walletId')}, :type, :amount, '
      ':balanceBefore, :balanceAfter, :refType, '
      "${referenceId != null ? uuidParam('refId') : 'NULL'}, "
      ':notes, ${createdBy != null ? uuidParam('createdBy') : 'NULL'})',
      {
        'id': entryId,
        'walletId': walletId,
        'type': transactionType,
        'amount': amount,
        'balanceBefore': balanceBefore,
        'balanceAfter': balanceAfter,
        'refType': referenceType,
        if (referenceId != null) 'refId': referenceId,
        'notes': notes,
        if (createdBy != null) 'createdBy': createdBy,
      },
    );
  }

  Future<Map<String, dynamic>> createTransaction({
    required String walletId,
    required String transactionType,
    required double amount,
    required String createdBy,
    String? notes,
  }) async {
    final wallet = await findById(walletId);
    if (wallet == null) throw ApiError.notFound('Wallet not found');

    final balance = double.parse(wallet['balance']?.toString() ?? '0');

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
        balanceBefore: balance,
        createdBy: createdBy,
        notes: notes,
      );

      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id, details_json) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId, :details)',
        {
          'auditId': generateUuid(),
          'userId': createdBy,
          'action': 'WALLET_TRANSACTION',
          'targetType': 'wallet',
          'targetId': walletId,
          'details': '{"type":"$transactionType","amount":$amount}',
        },
      );
    });

    // Return the created ledger entry
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(wallet_id),1,8),'-',SUBSTR(HEX(wallet_id),9,4),'-',SUBSTR(HEX(wallet_id),13,4),'-',SUBSTR(HEX(wallet_id),17,4),'-',SUBSTR(HEX(wallet_id),21))) AS wallet_id, "
      'transaction_type, amount, balance_before, balance_after, notes, created_at '
      'FROM wallet_ledger WHERE ${uuidWhere('id', 'id')} LIMIT 1',
      {'id': entryId},
    );

    return _rowToMap(result.rows.first);
  }

  double _calculateNewBalance(
    double current,
    String type,
    double amount,
  ) {
    if (['deposit', 'refund', 'adjustment'].contains(type)) {
      return current + amount;
    }
    return current - amount;
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
