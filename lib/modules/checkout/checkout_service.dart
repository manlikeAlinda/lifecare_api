import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'checkout_repository.dart';

const _maxCheckoutShillings = 5000000; // 5 M UGX — same ceiling as deposits

class CheckoutService {
  final CheckoutRepository _repo;
  final WalletRepository _walletRepo;

  CheckoutService(this._repo, this._walletRepo);

  Future<Map<String, dynamic>> checkout({
    required String patientId,
    required int amountShillings,
    required String description,
    String? referenceId,
    required String idempotencyKey,
  }) async {
    if (amountShillings <= 0) {
      throw ApiError.validationError('Amount must be greater than zero');
    }
    if (amountShillings > _maxCheckoutShillings) {
      throw ApiError.validationError('Maximum checkout is UGX $_maxCheckoutShillings');
    }

    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) throw ApiError.notFound('Wallet not found for this patient');
    final walletId = wallet['id'] as String;

    final checkoutId = generateUuid();
    try {
      await _repo.checkout(
        checkoutId: checkoutId,
        walletId: walletId,
        patientId: patientId,
        amountShillings: amountShillings,
        description: description,
        referenceId: referenceId,
        idempotencyKey: idempotencyKey,
        actorId: patientId,
      );
    } catch (e) {
      if (e.toString().contains('1062')) {
        // Retried attempt with the same idempotency key — return the
        // original result rather than debiting a second time.
        final existing = await _repo.findByIdempotencyKey(
          walletId: walletId,
          idempotencyKey: idempotencyKey,
        );
        if (existing != null) return existing;
      }
      rethrow;
    }

    return (await _repo.findById(checkoutId))!;
  }
}
