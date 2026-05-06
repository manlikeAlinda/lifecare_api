import 'package:mysql_client/mysql_client.dart';
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
}
