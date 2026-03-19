import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'patient_service.dart';

class PatientHandler {
  final PatientService _service;

  PatientHandler(this._service);

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final search = queryParam(request, 'search');

    final (patients, total) = await _service.listPatients(
      limit: limit,
      offset: offset,
      search: search,
    );
    return okListResponse(patients, total: total, limit: limit, offset: offset);
  }

  Future<Response> create(Request request) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('full_name')
      ..phoneE164('phone_e164')
      ..throwIfInvalid();

    final patient = await _service.createPatient(body, caller.id);
    return createdResponse(patient);
  }

  Future<Response> getById(Request request, String id) async {
    final patient = await _service.getPatient(id);
    return okResponse(patient);
  }

  Future<Response> update(Request request, String id) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..phoneE164('phone_e164')
      ..throwIfInvalid();

    final patient = await _service.updatePatient(id, body, caller.id);
    return okResponse(patient);
  }

  Future<Response> bulkUpdate(Request request) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('patients')
      ..isList('patients')
      ..throwIfInvalid();

    final updates = (body['patients'] as List).cast<Map<String, dynamic>>();
    await _service.bulkUpdatePatients(updates, caller.id);
    return noContentResponse();
  }

  Future<Response> delete(Request request, String id) async {
    final caller = requireAuthUser(request);
    await _service.deletePatient(id, caller.id);
    return noContentResponse();
  }

  // ── Dependents ──────────────────────────────────────────────────────────────

  Future<Response> listDependents(Request request, String patientId) async {
    final dependents = await _service.listDependents(patientId);
    return okListResponse(dependents, total: dependents.length);
  }

  Future<Response> createDependent(Request request, String patientId) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('full_name')
      ..required('relationship')
      ..phoneE164('phone_number')
      ..throwIfInvalid();

    final dep = await _service.createDependent(patientId, body);
    return createdResponse(dep);
  }

  Future<Response> updateDependent(
    Request request,
    String patientId,
    String depId,
  ) async {
    final body = await parseJsonBody(request);
    final dep = await _service.updateDependent(patientId, depId, body);
    return okResponse(dep);
  }

  Future<Response> deleteDependent(
    Request request,
    String patientId,
    String depId,
  ) async {
    await _service.deleteDependent(patientId, depId);
    return noContentResponse();
  }
}
