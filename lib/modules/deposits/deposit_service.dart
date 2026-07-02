import 'dart:convert';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/services/pesapal_service.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'deposit_repository.dart';

const _minDepositShillings = 500;
const _maxDepositShillings = 5000000; // 5 M UGX

class DepositService {
  final DepositRepository _depositRepo;
  final WalletRepository _walletRepo;
  final PesapalService _pesapal;

  DepositService(this._depositRepo, this._walletRepo, this._pesapal);

  // ── Initiate deposit ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> initiateDeposit({
    required String patientId,
    required int amountShillings,
    String? customerName,
    String? customerPhone,
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
      paymentMethod: 'PESAPAL',
    );

    Map<String, dynamic> pesapalResult;
    try {
      pesapalResult = await _pesapal.submitOrder(
        merchantReference: depositId,
        amountShillings: amountShillings,
        description: 'Lifecare wallet top-up',
        callbackUrl: '${AppConfig.publicUrl}/v1/deposits/return',
        customerName: customerName ?? 'Lifecare Patient',
        customerPhone: customerPhone ?? '',
      );
    } catch (e) {
      await _depositRepo.markFailed(depositId, e.toString());
      throw ApiError.internal('Could not reach payment provider — please try again');
    }

    // Store Pesapal's orderTrackingId so we can poll status later.
    await _depositRepo.setProviderRef(
        depositId, pesapalResult['orderTrackingId'] as String);

    return {
      'depositId': depositId,
      'redirectUrl': pesapalResult['redirectUrl'],
      'status': 'PENDING',
      'amountShillings': amountShillings,
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

    if (deposit['status'] == 'PENDING') {
      final trackingId = deposit['provider_ref'] as String?;
      if (trackingId != null) {
        try {
          final status = await _pesapal.getTransactionStatus(trackingId);
          if (status == 'COMPLETED') {
            await _creditWallet(deposit);
          } else if (status == 'FAILED') {
            await _depositRepo.markFailed(depositId, 'Payment declined by provider');
          }
          return (await _depositRepo.findById(depositId))!;
        } catch (e) {
          log.warning('Pesapal status probe failed for $depositId: $e');
        }
      }
    }

    return deposit;
  }

  // ── Pesapal IPN webhook handler ───────────────────────────────────────────────

  Future<void> handlePesapalIpn(Map<String, dynamic> payload) async {
    log.info('Pesapal IPN: ${jsonEncode(payload)}');

    final trackingId = payload['OrderTrackingId'] as String?
        ?? payload['orderTrackingId'] as String?;
    final merchantRef = payload['OrderMerchantReference'] as String?
        ?? payload['orderMerchantReference'] as String?;

    if (trackingId == null || merchantRef == null) {
      log.warning('Pesapal IPN missing required fields — ignored');
      return;
    }

    // Look up by provider_ref (trackingId) — NOT by merchantRef. This prevents
    // a replay where an attacker reuses a completed trackingId from their own
    // deposit to credit a different (larger) pending deposit.
    final deposit = await _depositRepo.findByProviderRef(trackingId);
    if (deposit == null) {
      log.warning('Pesapal IPN for unknown trackingId=$trackingId — ignored');
      return;
    }
    // Sanity: our stored depositId must match the merchantRef Pesapal sent.
    if (merchantRef.isNotEmpty && deposit['id'] != merchantRef) {
      log.warning(
        'Pesapal IPN trackingId=$trackingId belongs to deposit=${deposit['id']} '
        'but payload merchantRef=$merchantRef — possible replay, ignoring',
      );
      return;
    }

    await _depositRepo.saveMetadata(merchantRef, jsonEncode(payload));

    try {
      final status = await _pesapal.getTransactionStatus(trackingId);
      if (status == 'COMPLETED') {
        await _creditWallet(deposit);
      } else if (status == 'FAILED') {
        await _depositRepo.markFailed(merchantRef, 'Payment declined');
      }
    } catch (e) {
      log.warning('Pesapal IPN status verification failed for $trackingId: $e');
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  Future<void> _creditWallet(Map<String, dynamic> deposit) async {
    final depositId = deposit['id'] as String;
    final walletId = deposit['wallet_id'] as String;
    final amountShillings = (deposit['amount_shillings'] as int).toDouble();

    // Atomic: markSuccessful + wallet ledger entry in one transaction so a
    // crash between the two writes cannot leave a SUCCESSFUL deposit with an
    // uncredited wallet (no recovery path would exist after that).
    final credited = await _depositRepo.creditDepositTransaction(
      depositId: depositId,
      walletId: walletId,
      amountShillings: amountShillings,
    );

    if (!credited) {
      log.info('Deposit $depositId already processed — skipping credit');
      return;
    }

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
}
