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
    final statusParam = queryParam(request, 'status'); // 'active' | 'inactive' | null (all)

    final (patients, total) = await _service.listPatients(
      limit: limit,
      offset: offset,
      search: search,
      status: statusParam,
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

    final patient =
        await _service.createPatient(body, caller.id, isAdmin: caller.isAdmin);
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
      ..isListOfObjects('patients')
      ..throwIfInvalid();

    final updates = (body['patients'] as List).cast<Map<String, dynamic>>();
    await _service.bulkUpdatePatients(updates, caller.id);
    return noContentResponse();
  }

  Future<Response> bulkUpdateStatus(Request request) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('ids')
      ..isListOfStrings('ids')
      ..required('is_active')
      ..isBool('is_active')
      ..throwIfInvalid();

    final ids = (body['ids'] as List).cast<String>();
    final active = body['is_active'] as bool;
    await _service.bulkSetStatus(ids, active, caller.id);
    return noContentResponse();
  }

  Future<Response> bulkDelete(Request request) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('ids')
      ..isListOfStrings('ids')
      ..throwIfInvalid();

    final ids = (body['ids'] as List).cast<String>();
    await _service.bulkDeletePatients(ids, caller.id);
    return noContentResponse();
  }

  Future<Response> delete(Request request, String id) async {
    final caller = requireAuthUser(request);
    await _service.deletePatient(id, caller.id);
    return noContentResponse();
  }

  // ── PII encryption backfill (admin) ─────────────────────────────────────────

  Future<Response> backfillPiiEncryption(Request request) async {
    final result = await _service.backfillPiiEncryption();
    return okResponse(result);
  }

  // ── Beneficiaries (patient self-service, mobile app) ────────────────────────
  //
  // Response shape here is intentionally distinct from the staff-facing
  // `list`/`getById` shape — it matches what mobile/lib/features/profile/
  // beneficiaries_screen.dart's Beneficiary.fromJson expects.

  Map<String, dynamic> _toBeneficiaryJson(Map<String, dynamic> p) => {
        'id': p['id'] ?? '',
        'name': p['full_name'] ?? '',
        'relationship': p['relationship'] ?? '',
        'nationalId': p['national_id'] ?? '',
        'phone': p['phone_e164'] ?? '',
        'email': '',
        'status': (p['is_active'] == true || p['is_active'] == 1) ? 'active' : 'inactive',
        'addedOn': p['created_at']?.toString() ?? '',
        'isMinor': p['is_minor'] == true,
        'loginAccessStatus': p['login_access_status'] ?? 'no_login',
      };

  Future<Response> listBeneficiaries(Request request) async {
    final patient = requirePatientUser(request);
    final list = await _service.listOwnBeneficiaries(patient.id);
    return okListResponse(
      list.map(_toBeneficiaryJson).toList(),
      total: list.length,
    );
  }

  Future<Response> createBeneficiary(Request request) async {
    final patient = requirePatientUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('name')
      ..required('relationship')
      ..throwIfInvalid();

    final beneficiary = await _service.createOwnBeneficiary(patient.id, {
      'full_name': body['name'],
      'relationship': body['relationship'],
      'national_id': body['nationalId'],
      'phone': body['phone'],
      'is_minor': body['isMinor'] == true,
    });
    return createdResponse(_toBeneficiaryJson(beneficiary));
  }

  Future<Response> deleteBeneficiary(Request request, String beneficiaryId) async {
    final patient = requirePatientUser(request);
    await _service.deleteOwnBeneficiary(patient.id, beneficiaryId);
    return noContentResponse();
  }

  Future<Response> requestBeneficiaryLoginAccess(
    Request request,
    String beneficiaryId,
  ) async {
    final patient = requirePatientUser(request);
    final result = await _service.requestLoginAccess(patient.id, beneficiaryId);
    return okResponse(result);
  }

  // ── Admin — login-access-request queue ──────────────────────────────────────

  Future<Response> listLoginAccessRequests(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final status = queryParam(request, 'status');
    final (requests, total) = await _service.listLoginAccessRequests(
      limit: limit,
      offset: offset,
      status: status,
    );
    return okListResponse(requests, total: total, limit: limit, offset: offset);
  }

  Future<Response> rejectLoginAccessRequest(Request request, String requestId) async {
    final caller = requireAuthUser(request);
    await _service.rejectLoginAccessRequest(requestId, caller.id);
    return noContentResponse();
  }

  // ── Dependents ──────────────────────────────────────────────────────────────

  Future<Response> listDependents(Request request, String patientId) async {
    final dependents = await _service.listDependents(patientId);
    return okListResponse(dependents, total: dependents.length);
  }

  Future<Response> createDependent(Request request, String patientId) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('full_name')
      ..required('relationship')
      ..phoneE164('phone_e164')
      ..throwIfInvalid();

    final dep = await _service.createSubPatient(patientId, body, caller.id);
    return createdResponse(dep);
  }

  Future<Response> updateDependent(
    Request request,
    String patientId,
    String depId,
  ) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..phoneE164('phone_e164')
      ..throwIfInvalid();

    final dep = await _service.updateSubPatient(depId, body, caller.id);
    return okResponse(dep);
  }

  Future<Response> deleteDependent(
    Request request,
    String patientId,
    String depId,
  ) async {
    final caller = requireAuthUser(request);
    await _service.deleteSubPatient(depId, caller.id);
    return noContentResponse();
  }
}
