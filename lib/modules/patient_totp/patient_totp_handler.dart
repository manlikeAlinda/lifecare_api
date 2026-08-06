import 'package:shelf/shelf.dart';

import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'patient_totp_service.dart';

class PatientTotpHandler {
  final PatientTotpService _service;

  PatientTotpHandler(this._service);

  Future<Response> setup(Request request) async {
    final user = requirePatientUser(request);
    final result = await _service.setup(user.id, user.phone);
    return okResponse(result);
  }

  Future<Response> enable(Request request) async {
    final user = requirePatientUser(request);
    final body = await parseJsonBody(request);
    Validator(body)
      ..required('code')
      ..minLength('code', 6)
      ..maxLength('code', 6)
      ..throwIfInvalid();

    await _service.enable(user.id, body['code'] as String);
    return okResponse({'message': 'Two-factor authentication enabled'});
  }

  Future<Response> disable(Request request) async {
    final user = requirePatientUser(request);
    final body = await parseJsonBody(request);
    Validator(body)
      ..required('code')
      ..minLength('code', 6)
      ..maxLength('code', 6)
      ..throwIfInvalid();

    await _service.disable(user.id, body['code'] as String);
    return okResponse({'message': 'Two-factor authentication disabled'});
  }
}
