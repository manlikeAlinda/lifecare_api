import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/catalog/catalog_repository.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'encounter_pricing_resolver.dart';
import 'encounter_repository.dart';

class EncounterService {
  final EncounterRepository _repo;
  final WalletRepository _walletRepo;
  final EncounterPricingResolver _pricing;

  EncounterService(this._repo, this._walletRepo, CatalogPriceLookup catalogRepo)
      : _pricing = EncounterPricingResolver(catalogRepo);

  Future<(List<Map<String, dynamic>>, int)> listEncounters({
    int limit = 20,
    int offset = 0,
    String? patientId,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
  }) =>
      _repo.findAll(
        limit: limit,
        offset: offset,
        patientId: patientId,
        status: status,
        dateFrom: dateFrom,
        dateTo: dateTo,
        search: search,
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
    final dependentId = data['dependent_id'] as String?;

    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) {
      throw ApiError.businessRule('No wallet found for this patient');
    }

    final rawServices = (data['services'] as List? ?? []).cast<Map<String, dynamic>>();
    // Accept both 'drug_lines' (Flutter client) and 'medications' (legacy) keys.
    final rawMedications = (data['drug_lines'] as List? ??
                         data['medications'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    final services = await _pricing.resolveServices(rawServices);
    final medications = await _pricing.resolveDrugs(rawMedications);
    final total = EncounterPricingResolver.sumTotal(services) +
        EncounterPricingResolver.sumTotal(medications);

    return _repo.create(
      encounterId: generateUuid(),
      patientId: patientId,
      dependentId: dependentId,
      walletId: wallet['id'] as String,
      totalCost: total,
      createdBy: createdBy,
      services: services,
      medications: medications,
      referenceNumber: data['reference_number'] as String?,
      serviceType: data['service_type'] as String?,
      visitedAt: data['visited_at'] as String?,
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

    // If services/drug_lines are included, recalculate total for wallet adjustment.
    final hasLines =
        data.containsKey('services') || data.containsKey('drug_lines');

    List<Map<String, dynamic>>? newServices;
    List<Map<String, dynamic>>? newMedications;
    double? newTotal;

    if (hasLines) {
      final rawServices = (data['services'] as List? ?? []).cast<Map<String, dynamic>>();
      final rawMedications = (data['drug_lines'] as List? ??
                        data['medications'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      newServices = await _pricing.resolveServices(rawServices);
      newMedications = await _pricing.resolveDrugs(rawMedications);
      newTotal = EncounterPricingResolver.sumTotal(newServices) +
          EncounterPricingResolver.sumTotal(newMedications);
    }

    // Resolve the wallet the same way encounter creation does — via
    // WalletRepository.findByPatientId, which correctly follows the
    // primary/dependent account link. The repository must not re-derive
    // this with its own naive join (see deleteEncounter for why that broke).
    String? walletId;
    if (newTotal != null) {
      final wallet =
          await _walletRepo.findByPatientId(encounter['patient_id'] as String);
      walletId = wallet?['id'] as String?;
    }

    final updated = await _repo.update(
      id,
      data,
      updatedBy,
      newServices: newServices,
      newMedications: newMedications,
      newTotal: newTotal,
      oldTotal: (encounter['total_cost'] as num?)?.toDouble() ?? 0,
      walletId: walletId,
    );
    return updated!;
  }

  Future<bool> deleteEncounter(String id, String deletedBy) async {
    final encounter = await _repo.findById(id);
    if (encounter == null) return false;

    // Resolve via WalletRepository.findByPatientId rather than a raw join on
    // encounters.patient_id, so beneficiaries (whose wallet is keyed to the
    // primary account holder, not their own patient_id) reverse correctly too.
    final wallet =
        await _walletRepo.findByPatientId(encounter['patient_id'] as String);

    return _repo.delete(id, deletedBy, walletId: wallet?['id'] as String?);
  }
}
