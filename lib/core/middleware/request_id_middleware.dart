import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

const _requestIdKey = 'lifecare.requestId';

Middleware requestIdMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final requestId = generateUuid();
      final updated = request.change(context: {_requestIdKey: requestId});
      final stopwatch = Stopwatch()..start();
      final response = await inner(updated);
      stopwatch.stop();
      log.info('${request.method} ${request.requestedUri.path}${request.requestedUri.query.isNotEmpty ? '?${request.requestedUri.query}' : ''} → ${response.statusCode} (${stopwatch.elapsedMilliseconds}ms)');
      return response;
    };
  };
}

String getRequestId(Request request) =>
    request.context[_requestIdKey] as String? ?? 'unknown';
