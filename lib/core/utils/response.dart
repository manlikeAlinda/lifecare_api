import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';

const _jsonHeaders = {'content-type': 'application/json'};

Response okResponse(Map<String, dynamic> data) => Response.ok(
      jsonEncode({'data': data}),
      headers: _jsonHeaders,
    );

Response okListResponse(
  List<dynamic> data, {
  int total = 0,
  int limit = 20,
  int offset = 0,
}) =>
    Response.ok(
      jsonEncode({
        'data': data,
        'meta': {'total': total, 'limit': limit, 'offset': offset},
      }),
      headers: _jsonHeaders,
    );

Response createdResponse(Map<String, dynamic> data) => Response(
      201,
      body: jsonEncode({'data': data}),
      headers: _jsonHeaders,
    );

Response noContentResponse() => Response(204);

Response errorResponse(ApiError error, String requestId) => Response(
      error.statusCode,
      body: jsonEncode(error.toJson(requestId)),
      headers: _jsonHeaders,
    );

Future<Map<String, dynamic>> parseJsonBody(Request request) async {
  final body = await request.readAsString();
  if (body.isEmpty) return {};
  try {
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    throw ApiError.validationError('Invalid JSON body');
  }
}

int parseOffset(Request request, {int defaultValue = 0}) {
  final param = request.url.queryParameters['offset'];
  if (param == null) return defaultValue;
  return int.tryParse(param) ?? defaultValue;
}

int parseLimit(Request request, {int defaultValue = 20, int max = 100}) {
  final param = request.url.queryParameters['limit'];
  if (param == null) return defaultValue;
  return (int.tryParse(param) ?? defaultValue).clamp(1, max);
}

String? queryParam(Request request, String key) =>
    request.url.queryParameters[key];
