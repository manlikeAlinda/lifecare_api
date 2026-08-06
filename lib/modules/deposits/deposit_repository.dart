import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart' as audit;
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

class DepositRepository {
  final MySQLConnectionPool _pool;

  DepositRepository(this._pool);

  static final _select = '''
    SELECT
      ${uuidSelect('deposit_id', 'id')},
      ${uuidSelect('wallet_id',  'wallet_id')},
      ${uuidSelect('patient_id', 'patient_id')},
      amount_shillings, payment_method, status,
      provider_ref, failure_reason, created_at, updated_at
    FROM deposits
  ''';

  // ── Create ───────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> create({
    required String depositId,
    required String walletId,
    required String patientId,
    required int amountShillings,
    required String paymentMethod,
    String? providerRef,
  }) async {
    await _pool.execute(
      '''INSERT INTO deposits
           (deposit_id, wallet_id, patient_id, amount_shillings,
            payment_method, status, provider_ref)
         VALUES
           (${uuidParam('depositId')}, ${uuidParam('walletId')},
            ${uuidParam('patientId')}, :amount, :method, 'PENDING', :providerRef)''',
      {
        'depositId': depositId,
        'walletId': walletId,
        'patientId': patientId,
        'amount': amountShillings,
        'method': paymentMethod,
        'providerRef': providerRef,
      },
    );
    final row = await findById(depositId);
    return row!;
  }

  // ── Read ─────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> findById(String depositId) async {
    final result = await _pool.execute(
      '$_select WHERE ${uuidWhere('deposit_id', 'id')} LIMIT 1',
      {'id': depositId},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByProviderRef(String providerRef) async {
    final result = await _pool.execute(
      '$_select WHERE provider_ref = :ref LIMIT 1',
      {'ref': providerRef},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  // ── Update status ─────────────────────────────────────────────────────────────

  /// Sets provider_ref on a newly-initiated deposit.
  Future<void> setProviderRef(String depositId, String providerRef) async {
    await _pool.execute(
      'UPDATE deposits SET provider_ref = :ref WHERE ${uuidWhere('deposit_id', 'id')}',
      {'ref': providerRef, 'id': depositId},
    );
  }

  /// Atomically transitions PENDING → SUCCESSFUL.
  /// Returns true only if this call performed the transition (idempotency guard).
  Future<bool> markSuccessful(String depositId) async {
    final result = await _pool.execute(
      '''UPDATE deposits SET status = 'SUCCESSFUL'
         WHERE ${uuidWhere('deposit_id', 'id')} AND status = 'PENDING' ''',
      {'id': depositId},
    );
    return result.affectedRows.toInt() > 0;
  }

  Future<void> markFailed(String depositId, String reason) async {
    await _pool.execute(
      '''UPDATE deposits SET status = 'FAILED', failure_reason = :reason
         WHERE ${uuidWhere('deposit_id', 'id')} AND status = 'PENDING' ''',
      {'id': depositId, 'reason': reason},
    );
  }

  Future<void> saveMetadata(String depositId, String jsonMetadata) async {
    await _pool.execute(
      'UPDATE deposits SET metadata = :meta WHERE ${uuidWhere('deposit_id', 'id')}',
      {'meta': jsonMetadata, 'id': depositId},
    );
  }

  /// Atomically transitions the deposit PENDING → SUCCESSFUL and credits the
  /// wallet in a single transaction so a crash between the two writes cannot
  /// leave a deposit SUCCESSFUL with an uncredited wallet.
  ///
  /// Returns true if this call performed the credit; false if already done
  /// (idempotent — safe to call from both IPN handler and status polling).
  Future<bool> creditDepositTransaction({
    required String depositId,
    required String walletId,
    required double amountShillings,
  }) async {
    bool credited = false;
    await _pool.transactional((conn) async {
      final result = await conn.execute(
        "UPDATE deposits SET status = 'SUCCESSFUL' "
        "WHERE ${uuidWhere('deposit_id', 'id')} AND status = 'PENDING'",
        {'id': depositId},
      );
      if (result.affectedRows.toInt() == 0) return; // already processed

      final entryId = generateUuid();
      final amountInt = amountShillings.round();

      await conn.execute(
        'INSERT INTO wallet_ledger (ledger_id, wallet_id, type, amount_shillings) '
        "VALUES (UNHEX(REPLACE(:entryId, '-', '')), "
        "UNHEX(REPLACE(:walletId, '-', '')), "
        "'deposit', :amount)",
        {'entryId': entryId, 'walletId': walletId, 'amount': amountInt},
      );

      await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings + :amount, '
        '    last_activity_at = NOW() '
        "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
        {'amount': amountInt, 'walletId': walletId},
      );

      credited = true;
    });
    return credited;
  }

  /// Reverses a SUCCESSFUL deposit: flips its status, debits the wallet by
  /// the deposit amount (zero-floor guarded), and records a
  /// 'deposit_reversal' ledger entry — atomically, so a crash mid-way can
  /// never leave a REVERSED deposit with an uncredited-back wallet, or vice
  /// versa. Idempotent: calling this twice on an already-reversed deposit
  /// returns false the second time, not a double debit.
  ///
  /// Ledger type is 'deposit_reversal', not 'refund' — WalletRepository's
  /// appendLedgerEntry treats 'refund' as a CREDIT type; a reversal is a
  /// debit, so reusing that name would misclassify it for any future code
  /// reading wallet_ledger.type to infer direction.
  ///
  /// Throws ApiError.businessRule if the wallet balance can't cover the
  /// reversal — same convention as WalletRepository.appendLedgerEntry's
  /// zero-floor guard — which rolls back the whole transaction, so the
  /// deposit status flip above is undone and the deposit stays SUCCESSFUL
  /// rather than being left half-reversed.
  Future<bool> reverseDepositTransaction({
    required String depositId,
    required String walletId,
    required String actorId,
    required int amountShillings,
    required String reason,
  }) async {
    var reversed = false;
    await _pool.transactional((conn) async {
      final update = await conn.execute(
        "UPDATE deposits SET status = 'REVERSED', failure_reason = :reason "
        "WHERE ${uuidWhere('deposit_id', 'id')} AND status = 'SUCCESSFUL'",
        {'id': depositId, 'reason': reason},
      );
      if (update.affectedRows.toInt() == 0) {
        return; // not SUCCESSFUL, or already reversed — nothing to do
      }

      final entryId = generateUuid();
      await conn.execute(
        'INSERT INTO wallet_ledger (ledger_id, wallet_id, type, amount_shillings) '
        "VALUES (${uuidParam('entryId')}, ${uuidParam('walletId')}, "
        "'deposit_reversal', :amount)",
        {'entryId': entryId, 'walletId': walletId, 'amount': amountShillings},
      );

      // Zero-floor guarded debit — same pattern as appendLedgerEntry's debit
      // branch. If the wallet has since been spent below the deposit
      // amount, this blocks the reversal rather than driving balance negative.
      final debit = await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings - :amount, '
        '    last_activity_at = NOW() '
        "WHERE ${uuidWhere('wallet_id', 'walletId')} "
        'AND balance_shillings >= :amount',
        {'amount': amountShillings, 'walletId': walletId},
      );
      if (debit.affectedRows.toInt() == 0) {
        throw ApiError.businessRule('Insufficient wallet balance to reverse deposit');
      }

      await audit.writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'DEPOSIT_REVERSED',
        targetType: 'deposit',
        targetIdUuid: depositId,
        after: {
          'wallet_id': walletId,
          'amount_shillings': amountShillings,
          'reason': reason,
        },
      );

      reversed = true;
    });
    return reversed;
  }
}
