import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'audit_service.dart';

class AuditHandler {
  final AuditService _service;

  AuditHandler(this._service);

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final (entries, total) = await _service.list(
      limit: limit,
      offset: offset,
      beneficiaryId: queryParam(request, 'beneficiaryId'),
      actorId: queryParam(request, 'actorId'),
      action: queryParam(request, 'action'),
    );
    return okListResponse(entries, total: total, limit: limit, offset: offset);
  }
}
