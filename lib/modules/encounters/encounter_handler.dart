import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'encounter_service.dart';

// Canonical status values — includes both API-originated and app-originated names.
const _validStatuses = ['open', 'closed', 'cancelled', 'completed', 'pending'];

class EncounterHandler {
  final EncounterService _service;

  EncounterHandler(this._service);

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final patientId = queryParam(request, 'patient_id');
    final status = queryParam(request, 'status');
    final dateFrom = queryParam(request, 'date_from');
    final dateTo = queryParam(request, 'date_to');
    final search = queryParam(request, 'search');

    final (encounters, total) = await _service.listEncounters(
      limit: limit,
      offset: offset,
      patientId: patientId,
      status: status,
      dateFrom: dateFrom,
      dateTo: dateTo,
      search: search,
    );
    return okListResponse(encounters, total: total, limit: limit, offset: offset);
  }

  Future<Response> create(Request request) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('patient_id')
      ..uuid('patient_id', label: 'patient_id')
      ..throwIfInvalid();

    final encounter = await _service.createEncounter(body, caller.id);
    return createdResponse(encounter);
  }

  Future<Response> getById(Request request, String id) async {
    final encounter = await _service.getEncounter(id);
    return okResponse(encounter);
  }

  Future<Response> update(Request request, String id) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..oneOf('status', _validStatuses)
      ..throwIfInvalid();

    final encounter = await _service.updateEncounter(id, body, caller.id);
    return okResponse(encounter);
  }

  Future<Response> updateStatus(Request request, String id) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('status')
      ..oneOf('status', _validStatuses)
      ..throwIfInvalid();

    final encounter = await _service.updateEncounter(
      id,
      {'status': body['status']},
      caller.id,
    );
    return okResponse(encounter);
  }

  Future<Response> delete(Request request, String id) async {
    final caller = requireAuthUser(request);
    await _service.deleteEncounter(id, caller.id);
    return noContentResponse();
  }
}
