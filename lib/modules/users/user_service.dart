import 'dart:convert';
import 'dart:typed_data';

import 'package:bcrypt/bcrypt.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'user_repository.dart';

const _allowedAvatarTypes = {'image/jpeg', 'image/png', 'image/webp'};
const _maxAvatarBytes = 5 * 1024 * 1024; // 5MB — matches client-side cap

class UserService {
  final UserRepository _repo;

  UserService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listUsers({
    int limit = 20,
    int offset = 0,
    String? role,
    bool? active = true,
  }) =>
      _repo.findAll(limit: limit, offset: offset, role: role, active: active);

  Future<Map<String, dynamic>> getUser(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    return user;
  }

  Future<Map<String, dynamic>> createUser(
    Map<String, dynamic> data,
    String actorId,
  ) async {
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
      actorId: actorId,
      role: data['role'] as String? ?? 'staff',
      email: data['email'] as String?,
    );

    return user;
  }

  Future<List<Map<String, dynamic>>> listRoles() => _repo.getRoles();

  Future<Map<String, dynamic>> updateUser(
    String id,
    Map<String, dynamic> data,
    String actorId,
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

    final updated = await _repo.update(id, allowed, actorId);
    return updated!;
  }

  /// Soft-deletes the user and revokes all active sessions atomically
  /// (see [UserRepository.deleteUser]).
  Future<void> deleteUser(String id, String actorId) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.deleteUser(id, actorId);
  }

  Future<void> changePassword(String id, String newPassword, String actorId) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');

    final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
    await _repo.updatePassword(id, newHash, actorId);
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

  Future<void> revokeAllSessions(String id, String actorId) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.revokeAllSessions(id, actorId);
  }

  Future<void> updateAvatar(
    String id,
    Map<String, dynamic> data,
    String actorId,
  ) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');

    final contentType = data['content_type'] as String?;
    final base64Body = data['image_base64'] as String?;
    if (contentType == null || base64Body == null) {
      throw ApiError.validationError(
        'content_type and image_base64 are required',
      );
    }
    if (!_allowedAvatarTypes.contains(contentType)) {
      throw ApiError.validationError(
        'Unsupported image type. Use JPEG, PNG, or WebP.',
      );
    }

    late final Uint8List bytes;
    try {
      bytes = base64Decode(base64Body);
    } on FormatException {
      throw ApiError.validationError('image_base64 is not valid base64');
    }

    if (bytes.isEmpty) {
      throw ApiError.validationError('Image data is empty');
    }
    if (bytes.length > _maxAvatarBytes) {
      throw ApiError.validationError(
        'Image exceeds the 5MB size limit',
      );
    }

    await _repo.updateAvatar(
      id: id,
      bytes: bytes,
      contentType: contentType,
      actorId: actorId,
    );
  }

  /// Returns null if the user has no avatar set — callers render the
  /// client-side default placeholder in that case, never a broken image.
  Future<Map<String, dynamic>?> getAvatar(String id) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    return _repo.getAvatar(id);
  }

  Future<Map<String, dynamic>> changeRole(String id, String role, String actorId) async {
    final user = await _repo.findById(id);
    if (user == null) throw ApiError.notFound('User not found');
    await _repo.updateRole(id, role, actorId);
    return (await _repo.findById(id))!;
  }
}
