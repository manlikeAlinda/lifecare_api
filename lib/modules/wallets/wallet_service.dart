import 'package:lifecare_api/core/errors/api_error.dart';
import 'wallet_repository.dart';

/// How money was paid at the desk — stored on wallet_ledger.payment_method
/// (migration 046) so the Deposits report can split takings by method.
const counterPaymentMethods = ['cash', 'mobile_money', 'card', 'bank'];

/// Validated body of POST /v1/wallets/:id/payments. Amounts are whole
/// shillings (UGX has no minor unit in practice); a fractional or
/// string amount is rejected rather than rounded, so what the cashier
/// typed is exactly what's credited.
({int amount, String method, String? reference, String? notes})
    parseCounterPayment(Map<String, dynamic> body) {
  final amount = body['amount'];
  if (amount is! int || amount <= 0) {
    throw ApiError.validationError(
      'amount must be a whole number of shillings greater than 0',
      details: [{'field': 'amount', 'message': 'Positive whole number required'}],
    );
  }
  final method = body['payment_method'];
  if (method is! String || !counterPaymentMethods.contains(method)) {
    throw ApiError.validationError(
      'payment_method must be one of: ${counterPaymentMethods.join(', ')}',
      details: [{'field': 'payment_method', 'message': 'Unknown payment method'}],
    );
  }
  String? trimmed(String key) {
    final v = (body[key] as String?)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  final reference = trimmed('payment_reference');
  if (reference != null && reference.length > 64) {
    throw ApiError.validationError('payment_reference must be 64 characters or fewer');
  }
  return (amount: amount, method: method, reference: reference, notes: trimmed('notes'));
}

class WalletService {
  final WalletRepository _repo;

  WalletService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listWallets({
    int limit = 20,
    int offset = 0,
  }) =>
      _repo.findAll(limit: limit, offset: offset);

  Future<Map<String, dynamic>> getWallet(String id) async {
    final wallet = await _repo.findById(id);
    if (wallet == null) throw ApiError.notFound('Wallet not found');
    return wallet;
  }

  Future<Map<String, dynamic>> getWalletByPatient(String patientId) async {
    final wallet = await _repo.findByPatientId(patientId);
    if (wallet == null) throw ApiError.notFound('Wallet not found for this patient');
    return wallet;
  }

  Future<(List<Map<String, dynamic>>, int)> getGlobalLedger({
    int limit = 50,
    int offset = 0,
    String? type,
    String? from,
    String? to,
  }) =>
      _repo.findAllLedger(limit: limit, offset: offset, type: type, from: from, to: to);

  Future<(List<Map<String, dynamic>>, int)> getWalletLedger(
    String walletId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final wallet = await _repo.findById(walletId);
    if (wallet == null) throw ApiError.notFound('Wallet not found');
    return _repo.getLedger(walletId, limit: limit, offset: offset);
  }

  Future<List<Map<String, dynamic>>> getWalletDependents(String walletId) async {
    final wallet = await _repo.findById(walletId);
    if (wallet == null) throw ApiError.notFound('Wallet not found');
    return _repo.findDependentsByWalletId(walletId);
  }

  /// Desk payment (cash / mobile money / card / bank) for any account type —
  /// the only way the front desk can take money in or clear a debt.
  Future<Map<String, dynamic>> recordCounterPayment(
    String walletId,
    Map<String, dynamic> body,
    String cashierId,
  ) {
    final p = parseCounterPayment(body);
    return _repo.recordCounterPayment(
      walletId: walletId,
      amount: p.amount,
      method: p.method,
      reference: p.reference,
      notes: p.notes,
      cashierId: cashierId,
    );
  }

  static const _adjustmentScopedAccountTypes = {'corporate', 'remittance'};

  Future<Map<String, dynamic>> createTransaction(
    String walletId,
    Map<String, dynamic> data,
    String createdBy,
  ) async {
    final wallet = await _repo.findById(walletId);
    if (wallet == null) throw ApiError.notFound('Wallet not found');

    final validTypes = ['deposit', 'refund', 'adjustment', 'deduction', 'debt_created'];
    final type = data['transaction_type'] as String? ?? '';
    if (!validTypes.contains(type)) {
      throw ApiError.validationError(
        'transaction_type must be one of: ${validTypes.join(', ')}',
      );
    }

    final notes = (data['notes'] as String?)?.trim();

    if (type == 'adjustment') {
      // Matrix row: "Edit account balances" — a direct balance edit is only
      // permitted on corporate/bank-remittance accounts, never an
      // individual/family client's wallet. This endpoint is already
      // adminOnly at the route; this is the account-type scoping on top.
      final accountType = wallet['account_type'] as String?;
      if (accountType == null ||
          !_adjustmentScopedAccountTypes.contains(accountType)) {
        throw ApiError.forbidden(
          'Balance adjustments are only permitted on corporate or remittance accounts',
        );
      }
      // No balance mutation without a corresponding, reasoned transaction row.
      if (notes == null || notes.isEmpty) {
        throw ApiError.validationError(
          'A reason is required for balance adjustments',
        );
      }
      final amount = (data['amount'] as num?)?.toDouble() ?? 0;
      if (amount == 0) {
        throw ApiError.validationError('Adjustment amount must not be zero');
      }
    }

    return _repo.createTransaction(
      walletId: walletId,
      transactionType: type,
      amount: (data['amount'] as num).toDouble(),
      createdBy: createdBy,
      notes: notes,
    );
  }
}
