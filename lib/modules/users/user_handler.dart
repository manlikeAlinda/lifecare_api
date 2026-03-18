import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'user_service.dart';

class UserHandler {
  final UserService _service;

  UserHandler(this._service);

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final role = queryParam(request, 'role');

    final (users, total) = await _service.listUsers(
      limit: limit,
      offset: offset,
      role: role,
    );
    return okListResponse(users, total: total, limit: limit, offset: offset);
  }

  Future<Response> create(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('username')
      ..required('full_name')
      ..required('password')
      ..minLength('password', 8, label: 'Password')
      ..oneOf('role', ['admin', 'staff'])
      ..throwIfInvalid();

    final user = await _service.createUser(body);
    return createdResponse(user);
  }

  Future<Response> me(Request request) async {
    final caller = requireAuthUser(request);
    final user = await _service.getUser(caller.id);
    return okResponse(user);
  }

  Future<Response> getById(Request request, String id) async {
    final user = await _service.getUser(id);
    return okResponse(user);
  }

  Future<Response> update(Request request, String id) async {
    final body = await parseJsonBody(request);
    final user = await _service.updateUser(id, body);
    return okResponse(user);
  }

  Future<Response> delete(Request request, String id) async {
    // Users cannot delete themselves
    final caller = requireAuthUser(request);
    if (caller.id == id) {
      throw ApiError.businessRule('Cannot delete your own account');
    }
    await _service.deleteUser(id);
    return noContentResponse();
  }

  Future<Response> changePassword(Request request, String id) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    // Staff can only change their own password; admin can change anyone's
    if (!caller.isAdmin && caller.id != id) {
      throw ApiError.forbidden();
    }

    Validator(body)
      ..required('new_password')
      ..minLength('new_password', 8, label: 'New password')
      ..throwIfInvalid();

    await _service.changePassword(id, body);
    return noContentResponse();
  }

  Future<Response> changeRole(Request request, String id) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('role')
      ..oneOf('role', ['admin', 'staff'])
      ..throwIfInvalid();

    final user = await _service.changeRole(id, body['role'] as String);
    return okResponse(user);
  }
}
