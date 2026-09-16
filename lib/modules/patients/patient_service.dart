import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/patients/beneficiary_context.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'patient_repository.dart';

class PatientService {
  final PatientRepository _repo;

  PatientService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listPatients({
    int limit = 20,
    int offset = 0,
    String? search,
    String? status, // 'active' | 'inactive' | null = all
  }) {
    // null → show all; 'active' → active only; anything else → inactive only
    final bool? activeOnly = status == null
        ? null
        : status.toLowerCase() == 'active'
            ? true
            : false;
    return _repo.findAll(
      limit: limit,
      offset: offset,
      search: search,
      activeOnly: activeOnly,
    );
  }

  Future<Map<String, dynamic>> getPatient(String id) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    return patient;
  }

  Future<Map<String, dynamic>> createPatient(
    Map<String, dynamic> data,
    String createdBy, {
    required bool isAdmin,
  }) async {
    final id = generateUuid();
    final walletId = generateUuid();

    final fullName = data['full_name'] as String? ??
        '${data['first_name'] ?? ''} ${data['last_name'] ?? ''}'.trim();

    // Opening balance is admin-only (matrix row: "Add opening balance at
    // account creation") — gated here in the service, not the route, since
    // the route itself stays staff-accessible for the rest of the payload.
    // Staff-submitted opening_balance is silently ignored rather than
    // rejected, so the same create-account form works for both roles.
    final openingBalance = isAdmin
        ? (data['opening_balance'] as num?)?.toDouble()
        : null;

    // patient_code is never accepted from the client — the repository
    // always assigns the next LC-XXX sequence value server-side.
    return _repo.create(
      id: id,
      walletId: walletId,
      fullName: fullName,
      createdBy: createdBy,
      phone: data['phone'] as String? ?? data['phone_e164'] as String?,
      nationalId: data['national_id'] as String?,
      accountType: data['account_type'] as String? ?? 'individual',
      idType: data['id_type'] as String? ?? 'national_id',
      openingBalanceShillings:
          (openingBalance != null && openingBalance > 0) ? openingBalance : null,
    );
  }

  Future<Map<String, dynamic>> updatePatient(
    String id,
    Map<String, dynamic> data,
    String updatedBy,
  ) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    final updated = await _repo.update(id, data, updatedBy);
    return updated!;
  }

  Future<void> bulkUpdatePatients(
    List<Map<String, dynamic>> updates,
    String updatedBy,
  ) async {
    if (updates.isEmpty) return;
    for (final u in updates) {
      final id = u['id'] as String?;
      if (id == null) continue;
      final fields = Map<String, dynamic>.from(u)..remove('id');
      await _repo.update(id, fields, updatedBy);
    }
  }

  Future<void> bulkSetStatus(
    List<String> ids,
    bool active,
    String updatedBy,
  ) async {
    for (final id in ids) {
      await _repo.update(id, {'is_active': active ? 1 : 0}, updatedBy);
    }
  }

  Future<void> bulkDeletePatients(
    List<String> ids,
    String deletedBy,
  ) async {
    for (final id in ids) {
      final patient = await _repo.findById(id);
      if (patient == null) continue; // skip already-deleted
      await _repo.hardDelete(id);
    }
  }

  Future<void> deletePatient(String id, String deletedBy) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    await _repo.hardDelete(id);
  }

  // ── Sub-patients (beneficiaries) ────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listSubPatients(
    String primaryAccountId,
  ) async {
    await _ensurePatientExists(primaryAccountId);
    return _repo.findSubPatients(primaryAccountId);
  }

  Future<Map<String, dynamic>> createSubPatient(
    String primaryAccountId,
    Map<String, dynamic> data,
    String createdBy,
  ) async {
    final primary = await _repo.findById(primaryAccountId);
    if (primary == null) throw ApiError.notFound('Patient not found');

    final primaryCode = primary['patient_code'] as String? ?? '';
    final id = generateUuid();

    // Sub-patient code: primary code + short suffix — a different, server-
    // computed scheme from the main LC-XXX sequence, never client-supplied.
    final suffix = id.replaceAll('-', '').substring(0, 4).toUpperCase();
    final autoCode =
        primaryCode.isNotEmpty ? '$primaryCode-$suffix' : 'SUB-$suffix';

    return _repo.create(
      id: id,
      walletId: null, // Sub-patients share primary account's wallet
      fullName: data['full_name'] as String,
      createdBy: createdBy,
      patientCodeOverride: autoCode,
      phone: data['phone_e164'] as String? ?? data['phone'] as String?,
      nationalId: data['national_id'] as String?,
      accountType: 'dependent',
      primaryAccountId: primaryAccountId,
      relationship: data['relationship'] as String? ?? 'Relative',
      isMinor: data['is_minor'] == true,
    );
  }

  Future<Map<String, dynamic>> updateSubPatient(
    String subPatientId,
    Map<String, dynamic> data,
    String updatedBy,
  ) async {
    final patient = await _repo.findById(subPatientId);
    if (patient == null) throw ApiError.notFound('Beneficiary not found');
    final updated = await _repo.update(subPatientId, data, updatedBy);
    return updated!;
  }

  Future<void> deleteSubPatient(String subPatientId, String deletedBy) async {
    final patient = await _repo.findById(subPatientId);
    if (patient == null) throw ApiError.notFound('Beneficiary not found');
    await _repo.softDeleteSubPatient(subPatientId);
  }

  // ── Roster bulk import (Module 1 — corporate accounts) ──────────────────────

  static const _validIdTypes = {'national_id', 'passport', 'refugee_id', 'other'};
  static final _phoneRegex = RegExp(r'^\+[1-9]\d{7,14}$');

  /// All-or-nothing: validates every row first (structural + in-file
  /// duplicates + DB uniqueness) and returns the full list of failures if
  /// any exist, without inserting anything. Only once every row passes does
  /// it hand off to PatientRepository.bulkCreateSubPatients, which commits
  /// them all inside a single transaction.
  Future<List<Map<String, dynamic>>> bulkImportRoster(
    String corporateAccountId,
    List<Map<String, dynamic>> rows,
    String createdBy,
  ) async {
    final primary = await _repo.findById(corporateAccountId);
    if (primary == null) throw ApiError.notFound('Patient not found');
    if (primary['account_type'] != 'corporate') {
      throw ApiError.businessRule(
        'Roster import is only available for corporate accounts',
      );
    }
    if (rows.isEmpty) {
      throw ApiError.validationError('At least one roster row is required');
    }

    final errors = <Map<String, dynamic>>[];
    final seenPhones = <String>{};
    final seenIdValues = <String>{};

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];

      final fullName = (row['full_name'] as String?)?.trim() ?? '';
      if (fullName.isEmpty) {
        errors.add({'field': 'rows[$i].full_name', 'message': 'Full name is required'});
      }

      final relationship = (row['relationship'] as String?)?.trim() ?? '';
      if (relationship.isEmpty) {
        errors.add({'field': 'rows[$i].relationship', 'message': 'Relationship is required'});
      }

      final idType = (row['id_type'] as String?)?.trim();
      if (idType != null && idType.isNotEmpty && !_validIdTypes.contains(idType)) {
        errors.add({
          'field': 'rows[$i].id_type',
          'message': 'id_type must be one of: ${_validIdTypes.join(', ')}',
        });
      }

      final phone = (row['phone'] as String?)?.trim();
      if (phone != null && phone.isNotEmpty) {
        if (!_phoneRegex.hasMatch(phone)) {
          errors.add({
            'field': 'rows[$i].phone',
            'message': 'phone must be in E.164 format (e.g. +256700000000)',
          });
        } else if (!seenPhones.add(phone)) {
          errors.add({'field': 'rows[$i].phone', 'message': 'Duplicate phone number within this roster'});
        } else if (await _repo.phoneExists(phone)) {
          errors.add({'field': 'rows[$i].phone', 'message': 'Phone number is already registered'});
        }
      }

      final idValue = (row['id_value'] as String?)?.trim();
      if (idValue != null && idValue.isNotEmpty && !seenIdValues.add(idValue)) {
        errors.add({'field': 'rows[$i].id_value', 'message': 'Duplicate ID value within this roster'});
      }
    }

    if (errors.isNotEmpty) {
      throw ApiError.validationError('Roster import failed validation', details: errors);
    }

    return _repo.bulkCreateSubPatients(
      primaryAccountId: corporateAccountId,
      rows: rows,
      createdBy: createdBy,
    );
  }

  // ── Patient self-service beneficiaries (mobile app) ─────────────────────────
  //
  // Only the primary account holder (primary_account_id IS NULL) may manage
  // beneficiaries — a beneficiary calling these would otherwise be able to
  // add/remove siblings under an account they don't own. Reuses the same
  // sub-patient repo methods the staff-facing desktop routes already use.

  // A beneficiary has no sub-beneficiaries of their own — the data model
  // doesn't support beneficiary-of-a-beneficiary. This is the server-side
  // backstop: a beneficiary-scoped JWT replayed directly against this
  // endpoint must not be able to read the primary's sibling list either.
  Future<List<Map<String, dynamic>>> listOwnBeneficiaries(
    String requestingPatientId,
  ) async {
    final requester = await _repo.findById(requestingPatientId);
    if (requester == null) throw ApiError.notFound('Patient not found');
    if (isBeneficiaryRow(requester)) return const [];
    return _repo.findSubPatients(requestingPatientId);
  }

  Future<Map<String, dynamic>> createOwnBeneficiary(
    String requestingPatientId,
    Map<String, dynamic> data,
  ) async {
    final requester = await _repo.findById(requestingPatientId);
    if (requester == null) throw ApiError.notFound('Patient not found');
    if (requester['primary_account_id'] != null) {
      throw ApiError.forbidden('Only the primary account holder can manage beneficiaries');
    }
    return createSubPatient(requestingPatientId, data, requestingPatientId);
  }

  Future<void> deleteOwnBeneficiary(
    String requestingPatientId,
    String beneficiaryId,
  ) async {
    final requester = await _repo.findById(requestingPatientId);
    if (requester == null) throw ApiError.notFound('Patient not found');
    if (requester['primary_account_id'] != null) {
      throw ApiError.forbidden('Only the primary account holder can manage beneficiaries');
    }

    final beneficiary = await _repo.findById(beneficiaryId);
    if (beneficiary == null) throw ApiError.notFound('Beneficiary not found');
    if (beneficiary['primary_account_id'] != requestingPatientId) {
      throw ApiError.forbidden();
    }

    await _repo.softDeleteSubPatient(beneficiaryId);
  }

  // ── Beneficiary login access ────────────────────────────────────────────────

  Future<Map<String, dynamic>> requestLoginAccess(
    String requestingPatientId,
    String beneficiaryId,
  ) async {
    final requester = await _repo.findById(requestingPatientId);
    if (requester == null) throw ApiError.notFound('Patient not found');
    if (requester['primary_account_id'] != null) {
      throw ApiError.forbidden('Only the primary account holder can request login access');
    }

    final beneficiary = await _repo.findById(beneficiaryId);
    if (beneficiary == null) throw ApiError.notFound('Beneficiary not found');
    if (beneficiary['primary_account_id'] != requestingPatientId) {
      throw ApiError.forbidden();
    }
    if (beneficiary['is_minor'] == true) {
      throw ApiError.businessRule('Minor beneficiaries cannot request login access');
    }

    final status = beneficiary['login_access_status'] as String? ?? 'no_login';
    if (status != 'no_login') {
      throw ApiError.conflict(
          'A login-access request is already $status for this beneficiary');
    }

    return _repo.createLoginAccessRequest(
      beneficiaryId: beneficiaryId,
      primaryId: requestingPatientId,
    );
  }

  Future<(List<Map<String, dynamic>>, int)> listLoginAccessRequests({
    int limit = 20,
    int offset = 0,
    String? status,
  }) =>
      _repo.findLoginAccessRequests(limit: limit, offset: offset, status: status);

  Future<void> rejectLoginAccessRequest(String requestId, String actorId) =>
      _repo.rejectLoginAccessRequest(requestId: requestId, actorId: actorId);

  // ── Legacy aliases (kept so old dependents routes still work) ───────────────

  Future<List<Map<String, dynamic>>> listDependents(String patientId) =>
      listSubPatients(patientId);

  Future<Map<String, dynamic>> createDependent(
    String patientId,
    Map<String, dynamic> data,
    String createdBy,
  ) =>
      createSubPatient(patientId, data, createdBy);

  // ── PII encryption backfill (admin) ─────────────────────────────────────────

  Future<Map<String, int>> backfillPiiEncryption() => _repo.backfillPiiEncryption();

  // ── Private ──────────────────────────────────────────────────────────────────

  Future<void> _ensurePatientExists(String patientId) async {
    final patient = await _repo.findById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');
  }
}
