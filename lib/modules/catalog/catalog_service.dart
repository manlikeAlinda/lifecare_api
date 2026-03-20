import 'package:lifecare_api/core/errors/api_error.dart';
import 'catalog_repository.dart';

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
}
