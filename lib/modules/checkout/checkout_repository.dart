import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart' as audit;
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class CheckoutRepository {
  final MySQLConnectionPool _pool;

  CheckoutRepository(this._pool);

  static final _select =
      'SELECT '
      "${uuidSelect('checkout_id', 'id')}, "
      "${uuidSelect('wallet_id', 'wallet_id')}, "
      "${uuidSelect('patient_id', 'patient_id')}, "
      'amount_shillings, description, reference_id, idempotency_key, '
      'status, created_at '
      'FROM checkout_transactions';

  Future<Map<String, dynamic>?> findById(String checkoutId) async {
    final result = await _pool.execute(
      '$_select WHERE ${uuidWhere('checkout_id', 'id')} LIMIT 1',
      {'id': checkoutId},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByIdempotencyKey({
    required String walletId,
    required String idempotencyKey,
  }) async {
    final result = await _pool.execute(
      '$_select WHERE ${uuidWhere('wallet_id', 'walletId')} '
      'AND idempotency_key = :key LIMIT 1',
      {'walletId': walletId, 'key': idempotencyKey},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  /// Debits [walletId] by [amountShillings] and records the spend, atomically:
  /// row-locks the wallet (SELECT ... FOR UPDATE) so concurrent checkouts on
  /// the same wallet serialize instead of racing past a balance check, then
  /// inserts checkout_transactions + a 'deduction' wallet_ledger row and
  /// updates the balance, all in one transaction.
  ///
  /// Idempotent via UNIQUE(wallet_id, idempotency_key): a retry with the same
  /// key hits MySQL error 1062, which the caller (CheckoutService) catches
  /// and resolves by looking up the original row via
  /// [findByIdempotencyKey] — no second debit.
  ///
  /// Throws ApiError.businessRule if the wallet isn't ACTIVE or the balance
  /// can't cover the amount — matches the same throw-from-repo convention
  /// established in WalletRepository.appendLedgerEntry and
  /// DepositRepository.reverseDepositTransaction.
  Future<void> checkout({
    required String checkoutId,
    required String walletId,
    required String patientId,
    required int amountShillings,
    required String description,
    String? referenceId,
    required String idempotencyKey,
    required String actorId,
  }) async {
    await _pool.transactional((conn) async {
      final walletRows = await conn.execute(
        'SELECT status, balance_shillings FROM wallets '
        "WHERE ${uuidWhere('wallet_id', 'walletId')} FOR UPDATE",
        {'walletId': walletId},
      );
      if (walletRows.rows.isEmpty) {
        throw ApiError.notFound('Wallet not found');
      }
      final walletRow = walletRows.rows.first.assoc();
      if (walletRow['status'] != 'ACTIVE') {
        throw ApiError.businessRule('Wallet is not active');
      }
      final balance = int.parse(walletRow['balance_shillings'] ?? '0');
      if (balance < amountShillings) {
        throw ApiError.businessRule('Insufficient wallet balance');
      }

      await conn.execute(
        'INSERT INTO checkout_transactions '
        '(checkout_id, wallet_id, patient_id, amount_shillings, description, '
        ' reference_id, idempotency_key, status) '
        "VALUES (${uuidParam('checkoutId')}, ${uuidParam('walletId')}, "
        "${uuidParam('patientId')}, :amount, :description, :referenceId, "
        ":idempotencyKey, 'POSTED')",
        {
          'checkoutId': checkoutId,
          'walletId': walletId,
          'patientId': patientId,
          'amount': amountShillings,
          'description': description,
          'referenceId': referenceId,
          'idempotencyKey': idempotencyKey,
        },
      );

      final entryId = generateUuid();
      await conn.execute(
        'INSERT INTO wallet_ledger (ledger_id, wallet_id, type, amount_shillings) '
        "VALUES (${uuidParam('entryId')}, ${uuidParam('walletId')}, "
        "'deduction', :amount)",
        {'entryId': entryId, 'walletId': walletId, 'amount': amountShillings},
      );

      await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings - :amount, '
        '    last_activity_at = NOW() '
        "WHERE ${uuidWhere('wallet_id', 'walletId')}",
        {'amount': amountShillings, 'walletId': walletId},
      );

      await audit.writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'WALLET_CHECKOUT',
        targetType: 'wallet',
        targetIdUuid: walletId,
        after: {
          'checkout_id': checkoutId,
          'amount_shillings': amountShillings,
          'description': description,
          'reference_id': referenceId,
        },
      );
    });
  }
}
