import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'patient_repository.dart';

class PatientService {
  final PatientRepository _repo;

  PatientService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listPatients({
    int limit = 20,
    int offset = 0,
    String? search,
  }) =>
      _repo.findAll(limit: limit, offset: offset, search: search);

  Future<Map<String, dynamic>> getPatient(String id) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    return patient;
  }

  Future<Map<String, dynamic>> createPatient(
    Map<String, dynamic> data,
    String createdBy,
  ) async {
    final id = generateUuid();
    final walletId = generateUuid();

    final fullName = data['full_name'] as String? ??
        '${data['first_name'] ?? ''} ${data['last_name'] ?? ''}'.trim();

    return _repo.create(
      id: id,
      walletId: walletId,
      fullName: fullName,
      createdBy: createdBy,
      patientCode:
          data['patient_code'] as String? ?? data['patient_number'] as String?,
      phone: data['phone'] as String? ?? data['phone_e164'] as String?,
      nationalId: data['national_id'] as String?,
      accountType: data['account_type'] as String? ?? 'individual',
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

  Future<void> deletePatient(String id, String deletedBy) async {
    final patient = await _repo.findById(id);
    if (patient == null) throw ApiError.notFound('Patient not found');
    await _repo.softDelete(id, deletedBy);
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
    await _ensurePatientExists(primaryAccountId);

    final primary = await _repo.findById(primaryAccountId);
    final primaryCode = primary!['patient_code'] as String? ?? '';
    final id = generateUuid();

    // Auto-generate a sub-patient code from primary code + short suffix
    final suffix = id.replaceAll('-', '').substring(0, 4).toUpperCase();
    final autoCode = data['patient_code'] as String? ??
        (primaryCode.isNotEmpty ? '$primaryCode-$suffix' : 'SUB-$suffix');

    return _repo.create(
      id: id,
      walletId: null, // Sub-patients share primary account's wallet
      fullName: data['full_name'] as String,
      createdBy: createdBy,
      patientCode: autoCode,
      phone: data['phone_e164'] as String? ?? data['phone'] as String?,
      nationalId: data['national_id'] as String?,
      accountType: 'dependent',
      primaryAccountId: primaryAccountId,
      relationship: data['relationship'] as String? ?? 'Relative',
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
    await _repo.softDelete(subPatientId, deletedBy);
  }

  // ── Legacy aliases (kept so old dependents routes still work) ───────────────

  Future<List<Map<String, dynamic>>> listDependents(String patientId) =>
      listSubPatients(patientId);

  Future<Map<String, dynamic>> createDependent(
    String patientId,
    Map<String, dynamic> data,
    String createdBy,
  ) =>
      createSubPatient(patientId, data, createdBy);

  // ── Private ──────────────────────────────────────────────────────────────────

  Future<void> _ensurePatientExists(String patientId) async {
    final patient = await _repo.findById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');
  }
}
