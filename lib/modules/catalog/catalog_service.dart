import 'package:lifecare_api/core/errors/api_error.dart';
import 'catalog_repository.dart';

bool _parseBool(dynamic v) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  return false;
}

class CatalogService {
  final CatalogRepository _repo;

  CatalogService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listServices({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
  }) =>
      _repo.findServices(
        limit: limit,
        offset: offset,
        category: category,
        search: search,
      );

  Future<(List<Map<String, dynamic>>, int)> listDrugs({
    int limit = 20,
    int offset = 0,
    String? search,
    bool? active,
  }) =>
      _repo.findDrugs(limit: limit, offset: offset, search: search, active: active);

  Future<int> countDrugs({bool? active}) => _repo.countDrugs(active: active);

  Future<(List<Map<String, dynamic>>, int)> listAll({
    int limit = 20,
    int offset = 0,
    String? type,
    String? category,
    String? search,
  }) =>
      _repo.findAll(
        limit: limit,
        offset: offset,
        type: type,
        category: category,
        search: search,
      );

  Future<(List<Map<String, dynamic>>, int)> listByCategory(
    String category, {
    int limit = 20,
    int offset = 0,
    String? search,
  }) =>
      _repo.findByCategory(category, limit: limit, offset: offset, search: search);

  Future<Map<String, dynamic>> getItem(String id) async {
    final item = await _repo.findById(id);
    if (item == null) throw ApiError.notFound('Catalog item not found');
    return item;
  }

  Future<Map<String, dynamic>> createService(
    String domain,
    Map<String, dynamic> data,
  ) async {
    final item = await _repo.createByDomain(domain, data);
    if (item == null) throw ApiError.notFound('Unknown service domain: $domain');
    return item;
  }

  Future<Map<String, dynamic>> updateService(
    String domain,
    int id,
    Map<String, dynamic> data,
  ) async {
    final existing = await _repo.findByDomainAndId(domain, id);
    if (existing == null) throw ApiError.notFound('Service not found');
    final item = await _repo.updateByDomain(domain, id, data);
    return item!;
  }

  Future<void> deleteService(String domain, int id) async {
    final deleted = await _repo.deleteByDomain(domain, id);
    if (!deleted) throw ApiError.notFound('Service not found');
  }

  // ── Drug CRUD ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> createDrug(
    Map<String, dynamic> data,
    String actorId,
  ) async {
    final name = (data['name'] as String? ?? '').trim();
    final drugType = (data['drug_type'] as String? ?? 'Drugs').trim();
    final rawRate = data['rate'];
    final rate = rawRate is num
        ? rawRate.toDouble()
        : double.tryParse(rawRate?.toString() ?? '') ?? 0.0;
    final isActive = _parseBool(data['is_active'] ?? true);

    if (name.isEmpty) throw ApiError.validationError('name is required');
    if (rate <= 0) throw ApiError.validationError('rate must be greater than zero');

    final drug = await _repo.createDrug(
      name: name,
      drugType: drugType,
      rate: rate,
      isActive: isActive,
    );
    await _repo.writeDrugAudit(
      actorId: actorId,
      action: 'create_drug',
      drugId: drug['id'] as int,
    );
    return drug;
  }

  Future<Map<String, dynamic>> updateDrug(
    int id,
    Map<String, dynamic> data,
    String actorId,
  ) async {
    final existing = await _repo.findDrugById(id);
    if (existing == null) throw ApiError.notFound('Drug not found');

    final name = (data.containsKey('name')
            ? data['name'] as String? ?? ''
            : existing['name'] as String? ?? '')
        .trim();
    final drugType = (data.containsKey('drug_type')
            ? data['drug_type'] as String? ?? 'Drugs'
            : existing['drug_type'] as String? ?? 'Drugs')
        .trim();
    final rawRate = data.containsKey('rate')
        ? data['rate']
        : (existing['price'] ?? existing['rate']);
    final rate = rawRate is num
        ? rawRate.toDouble()
        : double.tryParse(rawRate?.toString() ?? '') ?? 0.0;
    final isActive = data.containsKey('is_active')
        ? _parseBool(data['is_active'])
        : _parseBool(existing['is_active']);

    if (name.isEmpty) throw ApiError.validationError('name is required');
    if (rate <= 0) throw ApiError.validationError('rate must be greater than zero');

    final drug =
        (await _repo.updateDrug(id, name: name, drugType: drugType, rate: rate, isActive: isActive))!;
    await _repo.writeDrugAudit(actorId: actorId, action: 'update_drug', drugId: id);
    return drug;
  }

  Future<void> deleteDrug(int id, String actorId) async {
    final existing = await _repo.findDrugById(id);
    if (existing == null) throw ApiError.notFound('Drug not found');

    final hasRefs = await _repo.drugHasEncounterReferences(id);
    if (hasRefs) {
      throw ApiError.conflict(
        'Drug is referenced in encounter records and cannot be deleted. Deactivate it instead.',
      );
    }

    await _repo.deleteDrug(id);
    await _repo.writeDrugAudit(actorId: actorId, action: 'delete_drug', drugId: id);
  }
}
