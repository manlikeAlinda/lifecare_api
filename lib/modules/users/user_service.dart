import 'package:bcrypt/bcrypt.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'user_repository.dart';

class UserService {
  final UserRepository _repo;

  UserService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listUsers({
    int limit = 20,
    int offset = 0,
    String? role,
  }) =>
      _repo.findAll(limit: limit, offset: offset, role: role);

  Future<Map<String, dynamic>> getUser(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    return user;
  }

  Future<Map<String, dynamic>> createUser(Map<String, dynamic> data) async {
    final existing = await _repo.findByUsername(data['username'] as String);
    if (existing != null) {
      throw ApiError.conflict('Username already taken');
    }

    final id = generateUuid();
    final passwordHash = BCrypt.hashpw(
      data['password'] as String,
      BCrypt.gensalt(),
    );

    final user = await _repo.create(
      id: id,
      username: data['username'] as String,
      fullName: data['full_name'] as String,
      passwordHash: passwordHash,
      role: data['role'] as String? ?? 'staff',
      email: data['email'] as String?,
    );

    return user;
  }

  Future<List<Map<String, dynamic>>> listRoles() => _repo.getRoles();

  Future<Map<String, dynamic>> updateUser(
    String id,
    Map<String, dynamic> data,
  ) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');

    final allowed = <String, dynamic>{};
    if (data['full_name'] != null) allowed['full_name'] = data['full_name'];
    // Only update email when the caller explicitly provides a non-empty value.
    final email = data['email'];
    if (email is String && email.isNotEmpty) allowed['email'] = email;
    if (data.containsKey('is_active')) {
      final v = data['is_active'];
      allowed['is_active'] = (v == true || v == 1) ? 1 : 0;
    }

    final updated = await _repo.update(id, allowed);
    return updated!;
  }

  Future<void> deleteUser(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.softDelete(id);
  }

  Future<void> changePassword(String id, String newPassword) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');

    final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
    await _repo.updatePassword(id, newHash);
  }

  Future<Map<String, dynamic>> getPreferences(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    return _repo.getPreferences(id);
  }

  Future<void> updatePreferences(String id, Map<String, dynamic> prefs) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.upsertPreferences(id, prefs);
  }

  Future<(List<Map<String, dynamic>>, int)> getUserAuditLog(
    String id, {
    int limit = 20,
    int offset = 0,
  }) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    return _repo.getAuditLog(id, limit: limit, offset: offset);
  }

  Future<void> revokeAllSessions(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.revokeAllSessions(id);
  }

  Future<Map<String, dynamic>> changeRole(String id, String role) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.updateRole(id, role);
    return (await _repo.findById(id))!;
  }
}
