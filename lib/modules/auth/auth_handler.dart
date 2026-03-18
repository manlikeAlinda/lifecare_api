import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'auth_service.dart';

class AuthHandler {
  final AuthService _service;

  AuthHandler(this._service);

  Future<Response> login(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('password')
      ..throwIfInvalid();

    final username = body['username'] as String?;
    final email = body['email'] as String?;

    if ((username == null || username.trim().isEmpty) &&
        (email == null || email.trim().isEmpty)) {
      throw ApiError.validationError('Validation failed', details: [
        {'field': 'username', 'message': 'username or email is required'},
      ]);
    }

    final result = await _service.login(
      username: username?.trim(),
      email: email?.trim(),
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
    return noContentResponse();
  }
}
