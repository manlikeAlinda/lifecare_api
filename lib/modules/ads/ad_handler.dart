import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'ad_service.dart';

class AdHandler {
  final AdService _service;

  AdHandler(this._service);

  // ── Admin (staff-authenticated) ─────────────────────────────────────────────

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final search = queryParam(request, 'search');

    final (items, total) = await _service.listForAdmin(
      limit: limit,
      offset: offset,
      search: search,
    );
    return okListResponse(items, total: total, limit: limit, offset: offset);
  }

  Future<Response> getById(Request request, String id) async {
    final ad = await _service.getById(id);
    return okResponse(ad);
  }

  Future<Response> create(Request request) async {
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('title')
      ..required('start_date')
      ..required('end_date')
      ..throwIfInvalid();

    final ad = await _service.create(body, actor.id);
    return createdResponse(ad);
  }

  Future<Response> update(Request request, String id) async {
    final actor = requireAuthUser(request);
    final body = await parseJsonBody(request);
    final ad = await _service.update(id, body, actor.id);
    return okResponse(ad);
  }

  /// Soft-delete (archive) — preserves the row for historical/audit purposes.
  Future<Response> archive(Request request, String id) async {
    final actor = requireAuthUser(request);
    await _service.archive(id, actor.id);
    return noContentResponse();
  }

  /// Permanent delete — admin-only (gated by the requireAdmin middleware on
  /// this route, not here), for when a row genuinely needs to be purged.
  Future<Response> hardDelete(Request request, String id) async {
    final actor = requireAuthUser(request);
    await _service.hardDelete(id, actor.id);
    return noContentResponse();
  }

  // ── Public (mobile carousel feed, no auth) ──────────────────────────────────

  Future<Response> listPublic(Request request) async {
    final items = await _service.listActiveForPublic();
    return okListResponse(items, total: items.length, limit: items.length);
  }
}
