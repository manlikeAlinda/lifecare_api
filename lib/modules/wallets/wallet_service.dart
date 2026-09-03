import 'package:lifecare_api/core/errors/api_error.dart';
import 'wallet_repository.dart';

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
