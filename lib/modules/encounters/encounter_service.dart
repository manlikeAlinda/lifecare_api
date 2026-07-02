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

    final services = (data['services'] as List? ?? []).cast<Map<String, dynamic>>();
    // Accept both 'drug_lines' (Flutter client) and 'medications' (legacy) keys.
    final medications = (data['drug_lines'] as List? ??
                         data['medications'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    double total = 0;
    for (final svc in services) {
      total += _lineTotal(svc, priceKey: 'unit_price', altPriceKey: 'price');
    }
    for (final med in medications) {
      total += _lineTotal(med, priceKey: 'unit_price', altPriceKey: 'rate');
    }

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

    double? newTotal;
    List<Map<String, dynamic>>? newServices;
    List<Map<String, dynamic>>? newMedications;

    if (hasLines) {
      newServices = (data['services'] as List? ?? []).cast<Map<String, dynamic>>();
      newMedications = (data['drug_lines'] as List? ??
                        data['medications'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      double total = 0;
      for (final svc in newServices) {
        total += _lineTotal(svc, priceKey: 'unit_price', altPriceKey: 'price');
      }
      for (final med in newMedications) {
        total += _lineTotal(med, priceKey: 'unit_price', altPriceKey: 'rate');
      }
      newTotal = total;
    }

    final updated = await _repo.update(
      id,
      data,
      updatedBy,
      newServices: newServices,
      newMedications: newMedications,
      newTotal: newTotal,
      oldTotal: (encounter['total_cost'] as num?)?.toDouble() ?? 0,
    );
    return updated!;
  }

  Future<bool> deleteEncounter(String id, String deletedBy) async {
    return _repo.delete(id, deletedBy);
  }

  static double _lineTotal(
    Map<String, dynamic> item, {
    required String priceKey,
    required String altPriceKey,
  }) {
    final preTotal = item['total_price'];
    if (preTotal != null) return _toDouble(preTotal);
    final price = _toDouble(item[priceKey] ?? item[altPriceKey]);
    final qty = _toDouble(item['quantity'] ?? 1);
    return price * qty;
  }

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
}
