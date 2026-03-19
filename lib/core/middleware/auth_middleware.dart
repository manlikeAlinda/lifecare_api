import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/middleware/request_id_middleware.dart';

const _authUserKey = 'lifecare.authUser';

class AuthUser {
  final String id;
  final String role;
  final String username;

  const AuthUser({
    required this.id,
    required this.role,
    required this.username,
  });

  bool get isAdmin => role.toLowerCase() == 'admin';
}

/// Verifies the JWT Bearer token and attaches [AuthUser] to the request context.
Middleware authMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final requestId = getRequestId(request);
      final authHeader = request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return errorResponse(ApiError.unauthenticated(), requestId);
      }

      final token = authHeader.substring(7);

      try {
        final jwt = JWT.verify(token, SecretKey(AppConfig.jwtSecret));
        final payload = jwt.payload as Map<String, dynamic>;

        if (payload['type'] != 'access') {
          return errorResponse(
            ApiError.unauthenticated('Invalid token type'),
            requestId,
          );
        }

        if (payload['sub_type'] == 'patient') {
          return Response.forbidden(
            jsonEncode({'error': 'Patient tokens are not valid for staff endpoints'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final authUser = AuthUser(
          id: payload['sub'] as String,
          role: payload['role'] as String,
          username: payload['username'] as String,
        );

        final updated = request.change(context: {_authUserKey: authUser});
        return inner(updated);
      } on JWTExpiredException {
        return errorResponse(ApiError.tokenExpired(), requestId);
      } on JWTException {
        return errorResponse(ApiError.unauthenticated('Invalid token'), requestId);
      }
    };
  };
}

/// Requires the authenticated user to have the 'admin' role.
Middleware requireAdmin() {
  return (Handler inner) {
    return (Request request) async {
      final requestId = getRequestId(request);
      final user = getAuthUser(request);
      if (user == null) return errorResponse(ApiError.unauthenticated(), requestId);
      if (!user.isAdmin) return errorResponse(ApiError.forbidden(), requestId);
      return inner(request);
    };
  };
}

AuthUser? getAuthUser(Request request) =>
    request.context[_authUserKey] as AuthUser?;

/// Retrieves the [AuthUser] from context or throws [ApiError.unauthenticated].
AuthUser requireAuthUser(Request request) {
  final user = getAuthUser(request);
  if (user == null) throw ApiError.unauthenticated();
  return user;
}
