import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_multipart/form_data.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
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

  // ── Corporate self-service roster CSV bulk-import ───────────────────────
  //
  // Distinct from bulkImportRoster further below (admin-only, JSON body,
  // all-or-nothing) — this is the corporate primary account holder's own
  // self-service path: multipart/form-data upload, partial-success (valid
  // rows commit even if others fail), authorization derived entirely from
  // the caller's own patient JWT (PatientService.bulkImportOwnRoster
  // rejects anyone who isn't that account's corporate primary).

  static const _rosterCsvMaxBytes = 2 * 1024 * 1024; // 2 MB — no limit of
  // any kind exists elsewhere in this server; this is the first one, and a
  // deliberately conservative default for a CSV upload, not derived from
  // an existing constraint.
  static const _rosterCsvMaxRows = 1000;
  static const _rosterCsvColumns = ['full_name', 'relationship', 'phone', 'national_id'];

  Future<Response> bulkImportOwnRoster(Request request) async {
    final patient = requirePatientUser(request);

    if (!request.isMultipartForm) {
      throw ApiError.validationError(
        'Expected a multipart/form-data upload with a single "file" field',
      );
    }

    // Content-Length is the fast path, checked before touching the body at
    // all — but it can be absent or wrong, so the running byte counter
    // below (while streaming the part) is the real guard against buffering
    // an unbounded upload into memory.
    final declaredLength = request.contentLength;
    if (declaredLength != null && declaredLength > _rosterCsvMaxBytes) {
      throw ApiError.validationError(
        'File is too large — the roster CSV must not exceed '
        '${_rosterCsvMaxBytes ~/ (1024 * 1024)} MB',
      );
    }

    String? csvContent;

    await for (final formData in request.multipartFormData) {
      // Exactly one field, named "file", carrying an actual file (not a
      // plain text field that happens to be named "file") — anything else
      // is rejected rather than guessed at.
      if (formData.name != 'file' || formData.filename == null || csvContent != null) {
        throw ApiError.validationError('Expected exactly one file field named "file"');
      }

      final builder = BytesBuilder();
      var total = 0;
      await for (final chunk in formData.part) {
        total += chunk.length;
        if (total > _rosterCsvMaxBytes) {
          throw ApiError.validationError(
            'File is too large — the roster CSV must not exceed '
            '${_rosterCsvMaxBytes ~/ (1024 * 1024)} MB',
          );
        }
        builder.add(chunk);
      }
      csvContent = utf8.decode(builder.takeBytes());
    }

    if (csvContent == null) {
      throw ApiError.validationError('No file was uploaded');
    }

    // shouldParseNumbers: false — otherwise an all-digit national_id or
    // phone value gets silently parsed to an int, breaking every downstream
    // String read.
    final table = const CsvToListConverter(shouldParseNumbers: false).convert(csvContent);
    if (table.isEmpty) {
      throw ApiError.validationError('The uploaded file is empty');
    }

    final header = table.first.map((c) => c.toString().trim()).toList();
    final headerMatches = header.length == _rosterCsvColumns.length &&
        _rosterCsvColumns.every(header.contains);
    if (!headerMatches) {
      throw ApiError.validationError(
        'CSV header must be exactly: ${_rosterCsvColumns.join(', ')}',
      );
    }
    final colIndex = {for (final name in header) name: header.indexOf(name)};

    // Drop fully-blank rows (a trailing newline in an Excel export is the
    // common real-world case) before they're mistaken for a genuine row
    // missing every field.
    final dataRows = table
        .skip(1)
        .where((row) => row.any((cell) => cell != null && cell.toString().trim().isNotEmpty))
        .toList();

    if (dataRows.isEmpty) {
      throw ApiError.validationError('The uploaded file has no data rows');
    }
    if (dataRows.length > _rosterCsvMaxRows) {
      throw ApiError.validationError(
        'The uploaded file must not exceed $_rosterCsvMaxRows rows',
      );
    }

    final rows = <Map<String, dynamic>>[
      for (var i = 0; i < dataRows.length; i++)
        {
          'row_number': i + 2, // header is row 1, matching how a
          // spreadsheet-literate uploader actually counts.
          'full_name': dataRows[i][colIndex['full_name']!]?.toString(),
          'relationship': dataRows[i][colIndex['relationship']!]?.toString(),
          'phone': dataRows[i][colIndex['phone']!]?.toString(),
          'national_id': dataRows[i][colIndex['national_id']!]?.toString(),
        },
    ];

    final result = await _service.bulkImportOwnRoster(patient.id, rows, patient.id);
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

  // ── Roster bulk import (Module 1) ────────────────────────────────────────────

  Future<Response> bulkImportRoster(Request request, String patientId) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('rows')
      ..isListOfObjects('rows')
      ..throwIfInvalid();

    final rows = (body['rows'] as List).cast<Map<String, dynamic>>();
    final created = await _service.bulkImportRoster(patientId, rows, caller.id);
    return okListResponse(created, total: created.length, limit: created.length, offset: 0);
  }

  // ── Cost centres & budget (admin — corporate accounts) ───────────────────

  Future<Response> listCostCentres(Request request, String corporateAccountId) async {
    final costCentres = await _service.listCostCentres(corporateAccountId);
    return okListResponse(costCentres, total: costCentres.length);
  }

  Future<Response> createCostCentre(Request request, String corporateAccountId) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)..required('name')..throwIfInvalid();

    final costCentre = await _service.createCostCentre(
      corporateAccountId,
      body['name'] as String,
      caller.id,
    );
    return createdResponse(costCentre);
  }

  Future<Response> renameCostCentre(Request request, String costCentreId) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)..required('name')..throwIfInvalid();

    final costCentre = await _service.renameCostCentre(
      costCentreId,
      body['name'] as String,
      caller.id,
    );
    return okResponse(costCentre);
  }

  Future<Response> retireCostCentre(Request request, String costCentreId) async {
    final caller = requireAuthUser(request);
    await _service.retireCostCentre(costCentreId, caller.id);
    return noContentResponse();
  }

  Future<Response> setBudget(Request request, String corporateAccountId) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)..currencyAmount('allocated_budget_shillings')..throwIfInvalid();

    final patient = await _service.setAllocatedBudget(
      corporateAccountId,
      body['allocated_budget_shillings'] as num?,
      caller.id,
    );
    return okResponse(patient);
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
