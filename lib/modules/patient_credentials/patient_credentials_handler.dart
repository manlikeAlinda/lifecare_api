import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'patient_credentials_service.dart';

class PatientCredentialsHandler {
  final PatientCredentialsService _service;

  PatientCredentialsHandler(this._service);

  Future<Response> generate(Request request, String patientId) async {
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);
    final email = body['email'] as String?;

    final result = await _service.generate(
      patientId,
      email: email,
      actorId: actor.id,
    );

    return okResponse(result);
  }

  Future<Response> getCredentials(Request request, String patientId) async {
    final result = await _service.getCredentials(patientId);
    return okResponse(result);
  }

  Future<Response> reset(Request request, String patientId) async {
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);
    final email = body['email'] as String?;

    final result = await _service.reset(
      patientId,
      email: email,
      actorId: actor.id,
    );

    return okResponse(result);
  }

  Future<Response> suspend(Request request, String patientId) async {
    final actor = requireAuthUser(request);

    final result = await _service.suspend(patientId, actorId: actor.id);
    return okResponse(result);
  }

  Future<Response> reinstate(Request request, String patientId) async {
    final actor = requireAuthUser(request);

    final result = await _service.reinstate(patientId, actorId: actor.id);
    return okResponse(result);
  }
}
