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

    // Support both old API (first_name + last_name) and new API (full_name)
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

  /// bulkUpdate is no longer supported with the simplified real-DB schema.
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

  // ── Dependents ──────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listDependents(String patientId) async {
    await _ensurePatientExists(patientId);
    return _repo.findDependents(patientId);
  }

  Future<Map<String, dynamic>> createDependent(
    String patientId,
    Map<String, dynamic> data,
  ) async {
    await _ensurePatientExists(patientId);
    return _repo.createDependent(
      patientId: patientId,
      depId: generateUuid(),
      fullName: data['full_name'] as String,
      nationalId: data['national_id'] as String? ?? '',
      relationship: data['relationship'] as String,
      phoneNumber: data['phone_number'] as String?,
    );
  }

  Future<Map<String, dynamic>> updateDependent(
    String patientId,
    String depId,
    Map<String, dynamic> data,
  ) async {
    final dep = await _repo.findDependentById(depId);
    if (dep == null) throw ApiError.notFound('Dependent not found');
    final updated = await _repo.updateDependent(depId, data);
    return updated!;
  }

  Future<void> deleteDependent(String patientId, String depId) async {
    final dep = await _repo.findDependentById(depId);
    if (dep == null) throw ApiError.notFound('Dependent not found');
    await _repo.softDeleteDependent(depId);
  }

  Future<void> _ensurePatientExists(String patientId) async {
    final patient = await _repo.findById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');
  }
}
