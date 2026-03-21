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

    return _repo.createTransaction(
      walletId: walletId,
      transactionType: type,
      amount: (data['amount'] as num).toDouble(),
      createdBy: createdBy,
      notes: data['notes'] as String?,
    );
  }
}
