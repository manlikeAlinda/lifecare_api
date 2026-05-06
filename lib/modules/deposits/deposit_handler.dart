import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/services/flutterwave_service.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'deposit_service.dart';

class DepositHandler {
  final DepositService _service;
  final FlutterwaveService _flw;

  DepositHandler(this._service, this._flw);

  // ── POST /v1/patient/deposit ──────────────────────────────────────────────────

  Future<Response> initiate(Request request) async {
    final patient = requirePatientUser(request);
    final body    = await parseJsonBody(request);

    final method         = (body['method'] as String? ?? '').toUpperCase();
    final amountRaw      = body['amount'];
    if (amountRaw == null) throw ApiError.validationError('amount is required');
    final amountShillings = (amountRaw as num).toInt();

    switch (method) {
      case 'MTN_MOMO':
        final phone = body['phone'] as String?;
        if (phone == null || phone.isEmpty) {
          throw ApiError.validationError('phone is required for MTN_MOMO');
        }
        final result = await _service.initiateMtnDeposit(
          patientId: patient.id,
          amountShillings: amountShillings,
          phone: phone,
        );
        return createdResponse(result);

      case 'CARD':
        final redirectUrl = body['redirectUrl'] as String?;
        if (redirectUrl == null || redirectUrl.isEmpty) {
          throw ApiError.validationError('redirectUrl is required for CARD');
        }
        final result = await _service.initiateCardDeposit(
          patientId: patient.id,
          amountShillings: amountShillings,
          customerPhone: patient.phone,
          customerName: body['customerName'] as String? ?? '',
          redirectUrl: redirectUrl,
        );
        return createdResponse(result);

      default:
        throw ApiError.validationError('method must be MTN_MOMO or CARD');
    }
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

  // ── POST /v1/webhooks/mtn ─────────────────────────────────────────────────────

  Future<Response> mtnWebhook(Request request) async {
    final body = await parseJsonBody(request);
    await _service.handleMtnWebhook(body);
    // MTN expects a 200 OK to stop retrying.
    return Response.ok('{"received":true}',
        headers: {'content-type': 'application/json'});
  }

  // ── POST /v1/webhooks/flutterwave ─────────────────────────────────────────────

  Future<Response> flutterwaveWebhook(Request request) async {
    // Verify the secret hash header before processing.
    final secretHash = request.headers['verif-hash'];
    if (!_flw.verifyWebhookSignature(secretHash)) {
      return Response.forbidden('{"error":"invalid signature"}',
          headers: {'content-type': 'application/json'});
    }

    final body = await parseJsonBody(request);
    await _service.handleFlutterwaveWebhook(body);
    return Response.ok('{"received":true}',
        headers: {'content-type': 'application/json'});
  }
}
