import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/middleware/request_id_middleware.dart';

const _authUserKey = 'lifecare.authUser';
const _patientUserKey = 'lifecare.patientUser';

class PatientUser {
  final String id;
  final String phone;
  final String patientCode;

  const PatientUser({
    required this.id,
    required this.phone,
    required this.patientCode,
  });
}

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

/// Verifies a patient JWT Bearer token and attaches [PatientUser] to the
/// request context. [findCredential] is injected (not imported directly —
/// core/ never depends on modules/ anywhere in this codebase, and this
/// keeps that intact) so the middleware can do a LIVE per-request
/// credential-status check, not just verify the JWT's signature/expiry.
///
/// This is what makes suspending a beneficiary's mobile access effectively
/// immediate rather than "rides out the access token's remaining ≤15-minute
/// life" — every authenticated request now re-checks
/// patient_credentials.status, not just login()/refresh().
Middleware patientAuthMiddleware(
  Future<Map<String, dynamic>?> Function(String patientId) findCredential,
) {
  return (Handler inner) {
    return (Request request) async {
      final requestId = getRequestId(request);
      final authHeader = request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return errorResponse(ApiError.unauthenticated(), requestId);
      }

      try {
        final jwt = JWT.verify(authHeader.substring(7), SecretKey(AppConfig.jwtSecret));
        final payload = jwt.payload as Map<String, dynamic>;

        if (payload['sub_type'] != 'patient') {
          return errorResponse(
            ApiError.forbidden('Patient token required'),
            requestId,
          );
        }

        final patientId = payload['sub'] as String;
        final credential = await findCredential(patientId);
        if (credential == null || credential['status'] == 'suspended') {
          return errorResponse(
            ApiError.forbidden('Account access has been suspended'),
            requestId,
          );
        }

        final patientUser = PatientUser(
          id: patientId,
          phone: payload['phone'] as String? ?? '',
          patientCode: payload['patient_code'] as String? ?? '',
        );

        final updated = request.change(context: {_patientUserKey: patientUser});
        return inner(updated);
      } on JWTExpiredException {
        return errorResponse(ApiError.tokenExpired(), requestId);
      } on JWTException {
        return errorResponse(ApiError.unauthenticated('Invalid token'), requestId);
      }
    };
  };
}

PatientUser? getPatientUser(Request request) =>
    request.context[_patientUserKey] as PatientUser?;

PatientUser requirePatientUser(Request request) {
  final user = getPatientUser(request);
  if (user == null) throw ApiError.unauthenticated();
  return user;
}
