import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'catalog_service.dart';

class CatalogHandler {
  final CatalogService _service;

  CatalogHandler(this._service);

  Future<Response> listServices(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final category = queryParam(request, 'category');
    final search = queryParam(request, 'search');

    final (items, total) = await _service.listServices(
      limit: limit,
      offset: offset,
      category: category,
      search: search,
    );
    return okListResponse(items, total: total, limit: limit, offset: offset);
  }

  Future<Response> listDrugs(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final search = queryParam(request, 'search');
    final activeParam = queryParam(request, 'active');
    final bool? active = activeParam == null
        ? null
        : activeParam == 'false' || activeParam == '0' ? false : true;

    final (items, total) = await _service.listDrugs(
      limit: limit,
      offset: offset,
      search: search,
      active: active,
    );
    return okListResponse(items, total: total, limit: limit, offset: offset);
  }

  Future<Response> countDrugs(Request request) async {
    final activeParam = queryParam(request, 'active');
    final bool? active = activeParam == null
        ? null
        : activeParam == 'false' || activeParam == '0' ? false : true;
    final total = await _service.countDrugs(active: active);
    return okResponse({'total': total});
  }

  Future<Response> listByCategory(Request request, String category) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final search = queryParam(request, 'search');

    final (items, total) = await _service.listByCategory(
      category,
      limit: limit,
      offset: offset,
      search: search,
    );
    return okListResponse(items, total: total, limit: limit, offset: offset);
  }

  Future<Response> getById(Request request, String id) async {
    final item = await _service.getItem(id);
    return okResponse(item);
  }
}
