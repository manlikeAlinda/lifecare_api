import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/config/app_config.dart';

// Origin is set by the browser from wherever the page actually runs — a
// third-party site can't spoof it as localhost — so matching any port here
// is safe and avoids re-allowlisting every `flutter run` dev session, which
// picks a new port each time.
final _localhostOrigin = RegExp(r'^https?://(localhost|127\.0\.0\.1)(:\d+)?$');

bool _isAllowedOrigin(String origin) =>
    _localhostOrigin.hasMatch(origin) || AppConfig.corsAllowedOrigins.contains(origin);

/// Handles CORS for browser-based clients (patient/corporate portal).
///
/// No `Access-Control-Allow-Credentials` — auth is a Bearer token in the
/// `Authorization` header, never a cookie, so the browser doesn't need
/// credentialed-mode CORS and an allowed origin can just be reflected back.
Middleware corsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      final allowed = origin != null && _isAllowedOrigin(origin);

      if (request.method == 'OPTIONS') {
        final headers = <String, String>{
          'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
          'Access-Control-Allow-Headers':
              request.headers['access-control-request-headers'] ?? 'Content-Type, Authorization',
          'Access-Control-Max-Age': '86400',
          'Vary': 'Origin',
          if (allowed) 'Access-Control-Allow-Origin': origin,
        };
        return Response(204, headers: headers);
      }

      final response = await inner(request);
      if (!allowed) return response;
      return response.change(headers: {
        'Access-Control-Allow-Origin': origin,
        'Vary': 'Origin',
      });
    };
  };
}
