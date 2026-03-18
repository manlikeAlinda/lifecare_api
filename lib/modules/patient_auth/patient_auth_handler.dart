import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'patient_auth_service.dart';

class PatientAuthHandler {
  final PatientAuthService _service;

  PatientAuthHandler(this._service);

  Future<Response> activate(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('phone')
      ..required('pin')
      ..required('new_password')
      ..throwIfInvalid();

    final result = await _service.activate(
      phone: body['phone'] as String,
      pin: body['pin'] as String,
      newPassword: body['new_password'] as String,
    );

    return okResponse(result);
  }

  Future<Response> login(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('phone')
      ..required('password')
      ..throwIfInvalid();

    final result = await _service.login(
      phone: body['phone'] as String,
      password: body['password'] as String,
    );

    return okResponse(result);
  }

  Future<Response> refresh(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('refresh_token')
      ..throwIfInvalid();

    final result = await _service.refresh(body['refresh_token'] as String);
    return okResponse(result);
  }

  Future<Response> logout(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('refresh_token')
      ..throwIfInvalid();

    await _service.logout(body['refresh_token'] as String);
    return okResponse({'message': 'Logged out'});
  }

  Future<Response> changePassword(Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final token = authHeader.substring(7);
    String patientId;

    try {
      final jwt = JWT.verify(token, SecretKey(AppConfig.jwtSecret));
      final payload = jwt.payload as Map<String, dynamic>;

      if (payload['sub_type'] != 'patient') {
        return Response(
          403,
          body: jsonEncode({'error': 'Only patient tokens are valid for this endpoint'}),
          headers: {'content-type': 'application/json'},
        );
      }

      patientId = payload['sub'] as String;
    } on JWTExpiredException {
      return Response(
        401,
        body: jsonEncode({'error': 'Access token has expired'}),
        headers: {'content-type': 'application/json'},
      );
    } on JWTException {
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid token'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final body = await parseJsonBody(request);

    Validator(body)
      ..required('current_password')
      ..required('new_password')
      ..throwIfInvalid();

    final result = await _service.changePassword(
      patientId: patientId,
      currentPassword: body['current_password'] as String,
      newPassword: body['new_password'] as String,
    );

    return okResponse(result);
  }
}
