import 'dart:convert';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/services/mtn_momo_service.dart';
import 'package:lifecare_api/core/services/flutterwave_service.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'deposit_repository.dart';

const _minDepositShillings = 500;
const _maxDepositShillings = 5000000; // 5 M UGX

class DepositService {
  final DepositRepository _depositRepo;
  final WalletRepository _walletRepo;
  final MtnMomoService _mtn;
  final FlutterwaveService _flw;

  DepositService(this._depositRepo, this._walletRepo, this._mtn, this._flw);

  // ── Initiate MTN MoMo deposit ────────────────────────────────────────────────

  Future<Map<String, dynamic>> initiateMtnDeposit({
    required String patientId,
    required int amountShillings,
    required String phone,
  }) async {
    _validateAmount(amountShillings);
    _validateMtnPhone(phone);

    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) throw ApiError.notFound('Wallet not found for this patient');

    final depositId = generateUuid();

    // Persist before calling the provider so we have a record even if the
    // MTN call succeeds but a later step fails.
    await _depositRepo.create(
      depositId: depositId,
      walletId: wallet['id'] as String,
      patientId: patientId,
      amountShillings: amountShillings,
      paymentMethod: 'MTN_MOMO',
      providerRef: depositId, // X-Reference-Id == depositId for easy webhook lookup
    );

    try {
      await _mtn.requestToPay(
        referenceId: depositId,
        amountShillings: amountShillings,
        phone: phone,
      );
    } catch (e) {
      await _depositRepo.markFailed(depositId, e.toString());
      throw ApiError.internal('Could not reach MTN MoMo — please try again');
    }

    final isSandbox = AppConfig.mtnTargetEnv == 'sandbox';
    return {
      'depositId': depositId,
      'status': 'PENDING',
      'method': 'MTN_MOMO',
      'amountShillings': amountShillings,
      'message': isSandbox
          ? '[SANDBOX] Approve the payment in your MTN MoMo sandbox app'
          : 'Check your phone and approve the MTN MoMo payment of UGX $amountShillings',
    };
  }

  // ── Initiate card deposit (Flutterwave hosted checkout) ───────────────────────

  Future<Map<String, dynamic>> initiateCardDeposit({
    required String patientId,
    required int amountShillings,
    required String customerPhone,
    required String customerName,
    required String redirectUrl,
  }) async {
    _validateAmount(amountShillings);

    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) throw ApiError.notFound('Wallet not found for this patient');

    final depositId = generateUuid();

    await _depositRepo.create(
      depositId: depositId,
      walletId: wallet['id'] as String,
      patientId: patientId,
      amountShillings: amountShillings,
      paymentMethod: 'CARD',
      providerRef: depositId, // tx_ref == depositId for easy webhook lookup
    );

    String paymentUrl;
    try {
      paymentUrl = await _flw.createPaymentLink(
        txRef: depositId,
        amountShillings: amountShillings,
        customerPhone: customerPhone,
        customerName: customerName,
        redirectUrl: redirectUrl,
      );
    } catch (e) {
      await _depositRepo.markFailed(depositId, e.toString());
      throw ApiError.internal('Could not create payment link — please try again');
    }

    return {
      'depositId': depositId,
      'status': 'PENDING',
      'method': 'CARD',
      'amountShillings': amountShillings,
      'paymentUrl': paymentUrl,
    };
  }

  // ── Get deposit status (patient polling) ──────────────────────────────────────

  Future<Map<String, dynamic>> getStatus({
    required String depositId,
    required String patientId,
  }) async {
    final deposit = await _depositRepo.findById(depositId);
    if (deposit == null) throw ApiError.notFound('Deposit not found');
    if (deposit['patient_id'] != patientId) throw ApiError.forbidden();

    // For PENDING MTN deposits, probe the provider for a live update.
    if (deposit['status'] == 'PENDING' && deposit['payment_method'] == 'MTN_MOMO') {
      final ref = deposit['provider_ref'] as String?;
      if (ref != null) {
        try {
          final mtnData = await _mtn.getTransactionStatus(ref);
          final mtnStatus = (mtnData['status'] as String? ?? '').toUpperCase();
          if (mtnStatus == 'SUCCESSFUL') {
            await _creditWallet(deposit);
          } else if (mtnStatus == 'FAILED') {
            final reason = mtnData['reason'] as String? ?? 'Payment declined';
            await _depositRepo.markFailed(depositId, reason);
          }
          return (await _depositRepo.findById(depositId))!;
        } catch (e) {
          log.warning('MTN status probe failed for $depositId: $e');
        }
      }
    }

    return deposit;
  }

  // ── MTN webhook handler ───────────────────────────────────────────────────────

  Future<void> handleMtnWebhook(Map<String, dynamic> payload) async {
    log.info('MTN webhook: ${jsonEncode(payload)}');

    // MTN echoes our X-Reference-Id as 'externalId' in the callback body.
    final ref = payload['externalId'] as String?
        ?? payload['referenceId'] as String?;
    if (ref == null) {
      log.warning('MTN webhook missing externalId/referenceId — ignored');
      return;
    }

    final deposit = await _depositRepo.findByProviderRef(ref);
    if (deposit == null) {
      log.warning('MTN webhook for unknown ref=$ref — ignored');
      return;
    }

    await _depositRepo.saveMetadata(deposit['id'] as String, jsonEncode(payload));

    final status = (payload['status'] as String? ?? '').toUpperCase();
    if (status == 'SUCCESSFUL') {
      await _creditWallet(deposit);
    } else if (status == 'FAILED') {
      final reason = payload['reason'] as String? ?? 'Payment declined by MTN';
      await _depositRepo.markFailed(deposit['id'] as String, reason);
    }
  }

  // ── Flutterwave webhook handler ───────────────────────────────────────────────

  Future<void> handleFlutterwaveWebhook(Map<String, dynamic> payload) async {
    log.info('Flutterwave webhook: event=${payload['event']}');

    if (payload['event'] != 'charge.completed') return;

    final txData = payload['data'] as Map<String, dynamic>?;
    final txRef  = txData?['tx_ref'] as String?;
    if (txData == null || txRef == null) return;

    final deposit = await _depositRepo.findByProviderRef(txRef);
    if (deposit == null) {
      log.warning('Flutterwave webhook for unknown tx_ref=$txRef — ignored');
      return;
    }

    await _depositRepo.saveMetadata(deposit['id'] as String, jsonEncode(payload));

    final flwStatus = (txData['status'] as String? ?? '').toLowerCase();
    if (flwStatus != 'successful') {
      await _depositRepo.markFailed(deposit['id'] as String, 'FLW status: $flwStatus');
      return;
    }

    // Independently verify with Flutterwave to guard against forged webhooks.
    final txId = txData['id']?.toString();
    if (txId != null) {
      final verified = await _flw.verifyTransaction(txId);
      if (verified == null) {
        log.warning('Flutterwave verification failed for tx=$txId — not crediting');
        return;
      }
      final verifiedAmount = ((verified['amount'] as num?) ?? 0).toInt();
      final expected = deposit['amount_shillings'] as int;
      if (verifiedAmount < expected) {
        log.warning('FLW amount mismatch: expected=$expected got=$verifiedAmount');
        await _depositRepo.markFailed(deposit['id'] as String, 'Amount mismatch');
        return;
      }
    }

    await _creditWallet(deposit);
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  /// Atomically marks the deposit SUCCESSFUL (guards against double-credit),
  /// then appends a 'deposit' ledger entry to the wallet.
  Future<void> _creditWallet(Map<String, dynamic> deposit) async {
    final depositId = deposit['id'] as String;

    // markSuccessful returns false if the deposit is already processed.
    final transitioned = await _depositRepo.markSuccessful(depositId);
    if (!transitioned) {
      log.info('Deposit $depositId already processed — skipping credit');
      return;
    }

    final walletId       = deposit['wallet_id'] as String;
    final amountShillings = (deposit['amount_shillings'] as int).toDouble();

    await _walletRepo.appendLedgerEntry(
      conn: _walletRepo.pool,
      entryId: generateUuid(),
      walletId: walletId,
      transactionType: 'deposit',
      amount: amountShillings,
    );

    log.info('Wallet credited: deposit=$depositId wallet=$walletId UGX=$amountShillings');
  }

  void _validateAmount(int shillings) {
    if (shillings < _minDepositShillings) {
      throw ApiError.validationError('Minimum deposit is UGX $_minDepositShillings');
    }
    if (shillings > _maxDepositShillings) {
      throw ApiError.validationError('Maximum deposit is UGX $_maxDepositShillings');
    }
  }

  void _validateMtnPhone(String phone) {
    final digits = phone.startsWith('+') ? phone.substring(1) : phone;
    if (!RegExp(r'^256[0-9]{9}$').hasMatch(digits)) {
      throw ApiError.validationError(
          'Phone must be a Uganda number: 256XXXXXXXXX or +256XXXXXXXXX');
    }
  }
}
