import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'auth_service.dart';

class AuthHandler {
  final AuthService _service;

  AuthHandler(this._service);

  Future<Response> login(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('username')
      ..required('password')
      ..throwIfInvalid();

    final result = await _service.login(
      username: body['username'] as String,
      password: body['password'] as String,
      deviceInfo: body['device_info'] as String?,
      ipAddress: request.headers['x-forwarded-for']?.split(',').first.trim() ??
          request.headers['x-real-ip'],
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
    return noContentResponse();
  }
}
