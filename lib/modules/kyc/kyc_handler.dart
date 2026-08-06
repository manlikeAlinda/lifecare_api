import 'package:shelf/shelf.dart';

import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'kyc_service.dart';

class KycHandler {
  final KycService _service;

  KycHandler(this._service);

  Future<Response> submit(Request request) async {
    final user = requirePatientUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('national_id')
      ..required('full_name')
      ..required('date_of_birth')
      ..throwIfInvalid();

    final result = await _service.submit(
      patientId: user.id,
      nationalId: body['national_id'] as String,
      fullName: body['full_name'] as String,
      dateOfBirth: body['date_of_birth'] as String,
      selfieUrl: body['selfie_url'] as String?,
      idFrontUrl: body['id_front_url'] as String?,
      idBackUrl: body['id_back_url'] as String?,
    );

    return okResponse(result);
  }

  Future<Response> status(Request request) async {
    final user = requirePatientUser(request);
    final result = await _service.getStatus(user.id);
    return okResponse(result);
  }

  /// Public route — no auth middleware, verified by payload signature
  /// instead (same shape as the existing Pesapal IPN handler).
  Future<Response> webhook(Request request) async {
    final body = await parseJsonBody(request);
    final result = await _service.handleWebhook(body);
    return okResponse(result ?? {'received': true});
  }
}
