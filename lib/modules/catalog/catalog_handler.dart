import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
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
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('name')
      ..throwIfInvalid();

    final item = await _service.createService(domain, body, actor.id);
    return createdResponse(item);
  }

  Future<Response> updateService(Request request, String domain, String id) async {
    final serviceId = int.tryParse(id);
    if (serviceId == null || serviceId <= 0) {
      throw ApiError.validationError('Invalid service id');
    }
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);
    final item = await _service.updateService(domain, serviceId, body, actor.id);
    return okResponse(item);
  }

  Future<Response> deleteService(Request request, String domain, String id) async {
    final serviceId = int.tryParse(id);
    if (serviceId == null || serviceId <= 0) {
      throw ApiError.validationError('Invalid service id');
    }
    final actor = requireAuthUser(request);
    await _service.deleteService(domain, serviceId, actor.id);
    return noContentResponse();
  }

  // ── Drug CRUD ──────────────────────────────────────────────────────────────

  Future<Response> createDrug(Request request) async {
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('name')
      ..throwIfInvalid();

    final item = await _service.createDrug(body, actor.id);
    return createdResponse(item);
  }

  Future<Response> updateDrug(Request request, String id) async {
    final actor = requireAuthUser(request);
    final drugId = int.tryParse(id);
    if (drugId == null || drugId <= 0) {
      throw ApiError.validationError('Invalid drug id');
    }
    final body = await parseJsonBody(request);
    final item = await _service.updateDrug(drugId, body, actor.id);
    return okResponse(item);
  }

  Future<Response> deleteDrug(Request request, String id) async {
    final actor = requireAuthUser(request);
    final drugId = int.tryParse(id);
    if (drugId == null || drugId <= 0) {
      throw ApiError.validationError('Invalid drug id');
    }
    await _service.deleteDrug(drugId, actor.id);
    return noContentResponse();
  }
}
