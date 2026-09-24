import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/patients/beneficiary_context.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'patient_repository.dart';

/// TIN eligibility + format check for a corporate patient record. Public,
/// side-effect-free (no DB/PII dependency) so it's independently unit-
/// testable — see test/modules/patients/tin_validation_test.dart.
///
/// TIN format is length-only (exactly 10 characters when present): URA's
/// exact character-class rules (numeric-only? leading zeros allowed?)
/// aren't confirmed, and a wrong regex risks rejecting valid TINs, which is
/// worse than under-validating. Never coerce to a numeric type here.
void validateTinSubmission({
  required String? idType,
  required String? nationalId,
  required String effectiveAccountType,
}) {
  if (idType != 'tin') return;
  if (effectiveAccountType != 'corporate') {
    throw ApiError.validationError(
      'id_type "tin" is only valid for corporate accounts',
      details: [
        {
          'field': 'id_type',
          'message': 'tin requires account_type to be "corporate"',
        },
      ],
    );
  }
  if (nationalId != null && nationalId.trim().length != 10) {
    throw ApiError.validationError(
      'TIN must be exactly 10 characters',
      details: [
        {'field': 'national_id', 'message': 'TIN must be exactly 10 characters'},
      ],
    );
  }
}

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

    final accountType = data['account_type'] as String? ?? 'individual';
    final idType = data['id_type'] as String? ?? 'national_id';
    validateTinSubmission(
      idType: idType,
      nationalId: data['national_id'] as String?,
      effectiveAccountType: accountType,
    );

    // patient_code is never accepted from the client — the repository
    // always assigns the next LC-XXX sequence value server-side.
    return _repo.create(
      id: id,
      walletId: walletId,
      fullName: fullName,
      createdBy: createdBy,
      phone: data['phone'] as String? ?? data['phone_e164'] as String?,
      nationalId: data['national_id'] as String?,
      accountType: accountType,
      idType: idType,
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

    final effectiveAccountType =
        data['account_type'] as String? ?? patient['account_type'] as String;
    final effectiveIdType =
        data['id_type'] as String? ?? patient['id_type'] as String?;
    final effectiveNationalId = data.containsKey('national_id')
        ? data['national_id'] as String?
        : patient['national_id'] as String?;
    validateTinSubmission(
      idType: effectiveIdType,
      nationalId: effectiveNationalId,
      effectiveAccountType: effectiveAccountType,
    );

    // _repo.update() only ever sees the raw partial payload, not the
    // existing row — if national_id is being changed on a record whose
    // effective id_type is 'tin' (inherited from the existing row, not
    // resent in this request), the repository still needs to know to
    // route it through the encrypted-only write path rather than plain
    // national_id.
    final updateData = (effectiveIdType == 'tin' && !data.containsKey('id_type'))
        ? {...data, 'id_type': 'tin'}
        : data;

    final updated = await _repo.update(id, updateData, updatedBy);
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
      await _repo.softDelete(id, deletedBy: deletedBy);
    }
  }

  Future<void> deletePatient(String id, String deletedBy) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    await _repo.softDelete(id, deletedBy: deletedBy);
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
    final primaryAccountId = patient['primary_account_id'] as String?;
    if (primaryAccountId == null) {
      throw ApiError.validationError('Not a beneficiary');
    }
    await _repo.unlinkBeneficiary(
      beneficiaryId: subPatientId,
      primaryAccountId: primaryAccountId,
      unlinkedBy: deletedBy,
    );
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
    if (!isCorporatePrimaryRow(primary)) {
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
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );

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

      final costCentreId = (row['cost_centre_id'] as String?)?.trim();
      if (costCentreId != null && costCentreId.isNotEmpty) {
        if (!uuidRegex.hasMatch(costCentreId)) {
          errors.add({
            'field': 'rows[$i].cost_centre_id',
            'message': 'cost_centre_id must be a valid UUID',
          });
        } else if (!await _repo.costCentreBelongsTo(costCentreId, corporateAccountId)) {
          errors.add({
            'field': 'rows[$i].cost_centre_id',
            'message': 'Unknown cost centre for this corporate account',
          });
        }
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

  // ── Cost centres & budget (admin — corporate accounts) ───────────────────

  Future<Map<String, dynamic>> _requireCorporateAccount(String id) async {
    final primary = await _repo.findById(id);
    if (primary == null) throw ApiError.notFound('Patient not found');
    if (!isCorporatePrimaryRow(primary)) {
      throw ApiError.businessRule('Cost centres are only available for corporate accounts');
    }
    return primary;
  }

  Future<List<Map<String, dynamic>>> listCostCentres(String corporateAccountId) async {
    await _requireCorporateAccount(corporateAccountId);
    return _repo.listCostCentres(corporateAccountId);
  }

  Future<Map<String, dynamic>> createCostCentre(
    String corporateAccountId,
    String name,
    String createdBy,
  ) async {
    await _requireCorporateAccount(corporateAccountId);
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ApiError.validationError('name is required');
    return _repo.createCostCentre(
      corporateAccountId: corporateAccountId,
      name: trimmed,
      createdBy: createdBy,
    );
  }

  Future<Map<String, dynamic>> renameCostCentre(
    String costCentreId,
    String name,
    String actorId,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ApiError.validationError('name is required');
    final updated = await _repo.renameCostCentre(costCentreId, trimmed, actorId: actorId);
    if (updated == null) throw ApiError.notFound('Cost centre not found');
    return updated;
  }

  Future<void> retireCostCentre(String costCentreId, String actorId) async {
    final retired = await _repo.retireCostCentre(costCentreId, actorId: actorId);
    if (!retired) throw ApiError.notFound('Cost centre not found');
  }

  Future<Map<String, dynamic>> setAllocatedBudget(
    String corporateAccountId,
    num? budgetShillings,
    String actorId,
  ) async {
    await _requireCorporateAccount(corporateAccountId);
    if (budgetShillings != null && budgetShillings < 0) {
      throw ApiError.validationError('allocated_budget_shillings must not be negative');
    }
    return _repo.setAllocatedBudget(
      corporateAccountId,
      budgetShillings?.toDouble(),
      actorId: actorId,
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
    final email = (data['email'] as String?)?.trim() ?? '';
    // Fail before creating anything if the email can't be stored, so a
    // create never half-succeeds (row saved, email silently dropped).
    if (email.isNotEmpty) await _repo.encryptEmail(email);
    final created =
        await createSubPatient(requestingPatientId, data, requestingPatientId);
    if (email.isEmpty) return created;
    await _repo.setEmail(created['id'] as String, email);
    return (await _repo.findById(created['id'] as String))!;
  }

  Future<Map<String, dynamic>> updateOwnBeneficiary(
    String requestingPatientId,
    String beneficiaryId,
    Map<String, dynamic> data,
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

    String? trimmed(String key) => (data[key] as String?)?.trim();
    final updated = await _repo.updateBeneficiary(
      beneficiaryId,
      updatedBy: requestingPatientId,
      fullName: trimmed('full_name'),
      relationship: trimmed('relationship'),
      nationalId: trimmed('national_id'),
      phone: trimmed('phone'),
      email: trimmed('email'),
      clearPhone: data['clear_phone'] == true,
      clearEmail: data['clear_email'] == true,
    );
    if (updated == null) throw ApiError.notFound('Beneficiary not found');
    return updated;
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

    await _repo.unlinkBeneficiary(
      beneficiaryId: beneficiaryId,
      primaryAccountId: requestingPatientId,
      unlinkedBy: requestingPatientId,
    );
  }

  // ── Corporate self-service roster CSV import ─────────────────────────────
  //
  // Distinct from bulkImportRoster above (admin-only, JSON, all-or-nothing):
  // caller is derived entirely from callerPatientId (the JWT subject) —
  // there is no account-id parameter anywhere in this method, deliberately,
  // matching PatientAnalyticsService._requireCorporateCaller's pattern, so
  // a corporate session can never target a different account's roster.
  // Partial-success: every row is validated up front (never short-circuits
  // on the first bad row), and only rows that pass every check are handed
  // to the repository, which inserts each independently so one row's
  // failure never rolls back its siblings.
  //
  // national_id's format check below is NOT a ported rule — no such
  // validator exists anywhere else in this codebase (manual single-
  // beneficiary entry applies none at all). It's a new, deliberately
  // conservative sanity check, since there's no verified national-ID format
  // spec to encode correctly.
  static final _nationalIdSanityRegex = RegExp(r'^[A-Za-z0-9]{4,20}$');

  Future<Map<String, dynamic>> bulkImportOwnRoster(
    String callerPatientId,
    List<Map<String, dynamic>> rows,
    String createdBy,
  ) async {
    final caller = await _repo.findById(callerPatientId);
    if (caller == null) throw ApiError.notFound('Patient not found');
    if (!isCorporatePrimaryRow(caller)) {
      throw ApiError.forbidden(
        'Roster import is only available to corporate account holders',
      );
    }

    // national_id is encrypted at rest with a randomized cipher (AES-GCM,
    // random IV per call) — nat_id_enc can never be looked up by equality,
    // so the only way to check "does this ID already exist under this
    // account" is to decrypt this account's own existing roster once,
    // up front, and compare in memory. Bounded to one account's
    // beneficiaries, not a global scan.
    final existingNationalIds = await _repo.listOwnNationalIds(callerPatientId);
    final seenPhones = <String>{};
    final seenNationalIds = <String>{};

    final valid = <Map<String, dynamic>>[];
    final failures = <Map<String, dynamic>>[];

    for (final row in rows) {
      final rowNumber = row['row_number'] as int;
      final errors = <String>[];

      final fullName = (row['full_name'] as String? ?? '').trim();
      if (fullName.isEmpty) {
        errors.add('full_name is required');
      } else if (fullName.length > 255) {
        // patients.full_name is VARCHAR(255) — db/schema.sql.
        errors.add('full_name must not exceed 255 characters');
      }

      // Validated, not silently overridden — every imported row still ends
      // up relationship='employee' at insert time either way, but a value
      // that isn't "Employee" (or blank) is a real data problem worth
      // surfacing, not quietly discarding.
      final relationship = (row['relationship'] as String? ?? '').trim();
      if (relationship.isNotEmpty && relationship.toLowerCase() != 'employee') {
        errors.add('relationship must be "Employee" (or left blank)');
      }

      final phoneRaw = (row['phone'] as String? ?? '').trim();
      String? phone;
      if (phoneRaw.isNotEmpty) {
        if (!_phoneRegex.hasMatch(phoneRaw)) {
          errors.add('phone must be in E.164 format (e.g. +256700000000)');
        } else if (!seenPhones.add(phoneRaw)) {
          errors.add('duplicate phone number within this file');
        } else if (await _repo.phoneExists(phoneRaw)) {
          errors.add('phone number is already registered');
        } else {
          phone = phoneRaw;
        }
      }

      final nationalIdRaw = (row['national_id'] as String? ?? '').trim();
      String? nationalId;
      if (nationalIdRaw.isNotEmpty) {
        if (!_nationalIdSanityRegex.hasMatch(nationalIdRaw)) {
          errors.add('national_id must be 4-20 alphanumeric characters');
        } else if (!seenNationalIds.add(nationalIdRaw)) {
          errors.add('duplicate national_id within this file');
        } else if (existingNationalIds.contains(nationalIdRaw)) {
          errors.add('national_id already exists for this account');
        } else {
          nationalId = nationalIdRaw;
        }
      }

      if (errors.isEmpty) {
        valid.add({
          'row_number': rowNumber,
          'full_name': fullName,
          'phone': phone,
          'national_id': nationalId,
        });
      } else {
        failures.add({'row': rowNumber, 'errors': errors});
      }
    }

    final outcomes = valid.isEmpty
        ? <Map<String, dynamic>>[]
        : await _repo.insertRosterRowsPartial(
            primaryAccountId: callerPatientId,
            rows: valid,
            createdBy: createdBy,
          );

    // Merge repository-level insert failures (rare races — e.g. the same
    // national ID imported by two concurrent uploads) into the same
    // failures list validation already produced, so the caller sees one
    // unified report regardless of which phase rejected a row.
    var importedCount = 0;
    for (final outcome in outcomes) {
      if (outcome['imported'] == true) {
        importedCount++;
      } else {
        failures.add({'row': outcome['row'], 'errors': outcome['errors']});
      }
    }

    failures.sort((a, b) => (a['row'] as int).compareTo(b['row'] as int));

    return {
      'total': rows.length,
      'imported': importedCount,
      'failed': rows.length - importedCount,
      'failures': failures,
    };
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
