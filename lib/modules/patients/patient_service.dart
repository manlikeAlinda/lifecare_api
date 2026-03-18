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

    return _repo.create(
      id: id,
      walletId: walletId,
      firstName: data['first_name'] as String,
      lastName: data['last_name'] as String,
      createdBy: createdBy,
      patientNumber: data['patient_number'] as String?,
      dateOfBirth: data['date_of_birth'] as String?,
      gender: data['gender'] as String?,
      phone: data['phone'] as String?,
      email: data['email'] as String?,
      address: data['address'] as String?,
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
    await _repo.bulkUpdate(updates, updatedBy);
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
      id: generateUuid(),
      patientId: patientId,
      firstName: data['first_name'] as String,
      lastName: data['last_name'] as String,
      dateOfBirth: data['date_of_birth'] as String?,
      gender: data['gender'] as String?,
      relationship: data['relationship'] as String?,
    );
  }

  Future<Map<String, dynamic>> updateDependent(
    String patientId,
    String depId,
    Map<String, dynamic> data,
  ) async {
    final dep = await _repo.findDependent(patientId, depId);
    if (dep == null) throw ApiError.notFound('Dependent not found');
    final updated = await _repo.updateDependent(patientId, depId, data);
    return updated!;
  }

  Future<void> deleteDependent(String patientId, String depId) async {
    final dep = await _repo.findDependent(patientId, depId);
    if (dep == null) throw ApiError.notFound('Dependent not found');
    await _repo.softDeleteDependent(patientId, depId);
  }

  Future<void> _ensurePatientExists(String patientId) async {
    final patient = await _repo.findById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');
  }
}
