import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class AuthRepository {
  final MySQLConnectionPool _pool;

  AuthRepository(this._pool);

  /// Returns user row or null. Selects fields needed for auth.
  Future<Map<String, dynamic>?> findUserByUsername(String username) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('id')}, '
      'username, full_name, role, password_hash, hash_algorithm, is_active '
      'FROM users WHERE username = :username LIMIT 1',
      {'username': username},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findUserById(String id) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('id')}, '
      'username, full_name, role, password_hash, hash_algorithm, is_active '
      'FROM users WHERE ${uuidWhere('id', 'id')} LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<void> updatePasswordHash(
    String userId,
    String hash,
    String algorithm,
  ) async {
    await _pool.execute(
      'UPDATE users SET password_hash = :hash, hash_algorithm = :algorithm, '
      'updated_at = NOW() WHERE ${uuidWhere('id', 'id')}',
      {'hash': hash, 'algorithm': algorithm, 'id': userId},
    );
  }

  Future<void> createSession({
    required String sessionId,
    required String userId,
    required String refreshTokenHash,
    required DateTime expiresAt,
    String? deviceInfo,
    String? ipAddress,
  }) async {
    await _pool.execute(
      'INSERT INTO sessions (id, user_id, refresh_token_hash, expires_at, device_info, ip_address) '
      'VALUES (${uuidParam('sessionId')}, ${uuidParam('userId')}, :refreshTokenHash, :expiresAt, :deviceInfo, :ipAddress)',
      {
        'sessionId': sessionId,
        'userId': userId,
        'refreshTokenHash': refreshTokenHash,
        'expiresAt': _formatDateTime(expiresAt),
        'deviceInfo': deviceInfo,
        'ipAddress': ipAddress,
      },
    );
  }

  Future<Map<String, dynamic>?> findActiveSession(String refreshTokenHash) async {
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('s.id')}, '
      '${uuidSelect('s.user_id', 'user_id')}, '
      's.expires_at, s.revoked_at, '
      '${uuidSelect('u.id', 'u_id')}, '
      'u.username, u.full_name, u.role, u.is_active '
      'FROM sessions s '
      'JOIN users u ON s.user_id = u.id '
      'WHERE s.refresh_token_hash = :hash '
      'AND s.revoked_at IS NULL '
      'AND s.expires_at > NOW() '
      'LIMIT 1',
      {'hash': refreshTokenHash},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<void> revokeSession(String sessionId) async {
    await _pool.execute(
      'UPDATE sessions SET revoked_at = NOW() WHERE ${uuidWhere('id', 'id')}',
      {'id': sessionId},
    );
  }

  Future<void> revokeSessionByToken(String refreshTokenHash) async {
    await _pool.execute(
      'UPDATE sessions SET revoked_at = NOW() WHERE refresh_token_hash = :hash',
      {'hash': refreshTokenHash},
    );
  }

  Future<void> revokeAllUserSessions(String userId) async {
    await _pool.execute(
      'UPDATE sessions SET revoked_at = NOW() '
      'WHERE ${uuidWhere('user_id', 'userId')} AND revoked_at IS NULL',
      {'userId': userId},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) {
    final assoc = row.assoc();
    return Map<String, dynamic>.from(assoc);
  }

  String _formatDateTime(DateTime dt) =>
      dt.toUtc().toString().replaceFirst('Z', '').substring(0, 19);
}
