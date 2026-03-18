import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'encounter_repository.dart';

class EncounterService {
  final EncounterRepository _repo;
  final WalletRepository _walletRepo;

  EncounterService(this._repo, this._walletRepo);

  Future<(List<Map<String, dynamic>>, int)> listEncounters({
    int limit = 20,
    int offset = 0,
    String? patientId,
    String? status,
    String? dateFrom,
    String? dateTo,
  }) =>
      _repo.findAll(
        limit: limit,
        offset: offset,
        patientId: patientId,
        status: status,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );

  Future<Map<String, dynamic>> getEncounter(String id) async {
    final encounter = await _repo.findById(id);
    if (encounter == null) throw ApiError.notFound('Encounter not found');
    return encounter;
  }

  Future<Map<String, dynamic>> createEncounter(
    Map<String, dynamic> data,
    String createdBy,
  ) async {
    final patientId = data['patient_id'] as String;

    // Get the patient's wallet
    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) {
      throw ApiError.businessRule('No wallet found for this patient');
    }

    final services = (data['services'] as List? ?? []).cast<Map<String, dynamic>>();
    final medications = (data['medications'] as List? ?? []).cast<Map<String, dynamic>>();

    // Calculate total
    double total = 0;
    for (final svc in services) {
      total += (svc['total_price'] as num?)?.toDouble() ?? 0;
    }
    for (final med in medications) {
      total += (med['total_price'] as num?)?.toDouble() ?? 0;
    }

    final balance = double.parse(wallet['balance']?.toString() ?? '0');
    if (total > balance) {
      throw ApiError.businessRule(
        'Insufficient wallet balance. Required: $total, Available: $balance',
      );
    }

    return _repo.create(
      encounterId: generateUuid(),
      patientId: patientId,
      walletId: wallet['id'] as String,
      totalAmount: total,
      walletBalanceBefore: balance,
      createdBy: createdBy,
      services: services,
      medications: medications,
      encounterNumber: data['encounter_number'] as String?,
      encounterType: data['encounter_type'] as String?,
      provider: data['provider'] as String?,
      notes: data['notes'] as String?,
      encounterDate: data['encounter_date'] as String?,
    );
  }

  Future<Map<String, dynamic>> updateEncounter(
    String id,
    Map<String, dynamic> data,
    String updatedBy,
  ) async {
    final encounter = await _repo.findById(id);
    if (encounter == null) throw ApiError.notFound('Encounter not found');

    if (encounter['status'] == 'cancelled') {
      throw ApiError.businessRule('Cannot update a cancelled encounter');
    }

    final updated = await _repo.update(id, data, updatedBy);
    return updated!;
  }

  Future<void> deleteEncounter(String id, String deletedBy) async {
    final encounter = await _repo.findById(id);
    if (encounter == null) throw ApiError.notFound('Encounter not found');

    if (encounter['status'] == 'cancelled') {
      throw ApiError.businessRule('Encounter is already cancelled');
    }

    await _repo.delete(id, deletedBy);
  }
}
