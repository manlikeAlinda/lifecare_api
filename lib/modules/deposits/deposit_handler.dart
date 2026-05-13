import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'deposit_service.dart';

class DepositHandler {
  final DepositService _service;

  DepositHandler(this._service);

  // ── POST /v1/patient/deposit ──────────────────────────────────────────────────

  Future<Response> initiate(Request request) async {
    final patient = requirePatientUser(request);
    final body    = await parseJsonBody(request);

    final amountRaw = body['amount'];
    if (amountRaw == null) throw ApiError.validationError('amount is required');
    final amountShillings = (amountRaw as num).toInt();

    final result = await _service.initiateDeposit(
      patientId:      patient.id,
      amountShillings: amountShillings,
      customerName:   body['customerName'] as String?,
      customerPhone:  patient.phone,
    );
    return createdResponse(result);
  }

  // ── GET /v1/patient/deposit/<id> ──────────────────────────────────────────────

  Future<Response> getStatus(Request request, String depositId) async {
    final patient = requirePatientUser(request);
    final deposit = await _service.getStatus(
      depositId: depositId,
      patientId: patient.id,
    );
    return okResponse(deposit);
  }

  // ── POST /v1/webhooks/pesapal ─────────────────────────────────────────────────

  Future<Response> pesapalIpn(Request request) async {
    final body = await parseJsonBody(request);

    final trackingId  = body['OrderTrackingId']        as String?
                     ?? body['orderTrackingId']         as String? ?? '';
    final merchantRef = body['OrderMerchantReference'] as String?
                     ?? body['orderMerchantReference']  as String? ?? '';
    final notifType   = body['OrderNotificationType']  as String?
                     ?? body['orderNotificationType']   as String? ?? 'IPNCHANGE';

    await _service.handlePesapalIpn(body);

    // Pesapal requires this exact response shape to stop retrying.
    return Response.ok(
      jsonEncode({
        'orderNotificationType':  notifType,
        'orderTrackingId':        trackingId,
        'orderMerchantReference': merchantRef,
        'status':                 '200',
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}
