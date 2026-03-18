import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

const _requestIdKey = 'lifecare.requestId';

Middleware requestIdMiddleware() {
  return (Handler inner) {
    return (Request request) {
      final requestId = generateUuid();
      final updated = request.change(context: {_requestIdKey: requestId});
      return inner(updated);
    };
  };
}

String getRequestId(Request request) =>
    request.context[_requestIdKey] as String? ?? 'unknown';
