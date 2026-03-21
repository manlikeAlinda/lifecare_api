import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
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

  Future<Response> createService(Request request, String domain) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('name')
      ..throwIfInvalid();

    final item = await _service.createService(domain, body);
    return createdResponse(item);
  }

  Future<Response> updateService(Request request, String domain, String id) async {
    final body = await parseJsonBody(request);
    final item = await _service.updateService(domain, int.parse(id), body);
    return okResponse(item);
  }

  Future<Response> deleteService(Request request, String domain, String id) async {
    await _service.deleteService(domain, int.parse(id));
    return noContentResponse();
  }
}
