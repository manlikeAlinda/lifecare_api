import 'package:shelf/shelf.dart';

import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'checkout_service.dart';

class CheckoutHandler {
  final CheckoutService _service;

  CheckoutHandler(this._service);

  Future<Response> checkout(Request request) async {
    final patient = requirePatientUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('amount')
      ..positiveInteger('amount')
      ..required('description')
      ..required('idempotency_key')
      ..throwIfInvalid();

    final amountRaw = body['amount'];
    final amountShillings =
        amountRaw is num ? amountRaw.toInt() : int.parse(amountRaw.toString());

    final result = await _service.checkout(
      patientId: patient.id,
      amountShillings: amountShillings,
      description: body['description'] as String,
      referenceId: body['reference_id'] as String?,
      idempotencyKey: body['idempotency_key'] as String,
    );
    return createdResponse(result);
  }
}
