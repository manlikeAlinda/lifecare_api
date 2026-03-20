import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

class AuthRepository {
  final MySQLConnectionPool _pool;

  AuthRepository(this._pool);

  // ── UUID helpers matching real DB column names ─────────────────────────────

  static String _uuidHex(String col, [String? alias]) {
    final a = alias ?? col;
    return "LOWER(CONCAT(SUBSTR(HEX($col),1,8),'-',SUBSTR(HEX($col),9,4),'-',"
        "SUBSTR(HEX($col),13,4),'-',SUBSTR(HEX($col),17,4),'-',"
        "SUBSTR(HEX($col),21))) AS $a";
  }

  // ── Users ──────────────────────────────────────────────────────────────────

  /// Returns user row or null. Also fetches the user's primary role.
  Future<Map<String, dynamic>?> findUserByUsername(String username) async {
    final result = await _pool.execute(
      'SELECT '
      '${_uuidHex('u.user_id', 'id')}, '
      'u.username, u.display_name AS full_name, u.is_active, '
      'HEX(u.password_hash) AS password_hash, u.password_alg AS hash_algorithm, '
      'COALESCE(r.role_key, \'staff\') AS role '
      'FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id '
      'WHERE u.username = :username LIMIT 1',
      {'username': username},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findUserByEmail(String email) async {
    final result = await _pool.execute(
      'SELECT '
      '${_uuidHex('u.user_id', 'id')}, '
      'u.username, u.display_name AS full_name, u.is_active, '
      'HEX(u.password_hash) AS password_hash, u.password_alg AS hash_algorithm, '
      'COALESCE(r.role_key, \'staff\') AS role '
      'FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id '
      'WHERE u.email = :email LIMIT 1',
      {'email': email},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findUserById(String id) async {
    final result = await _pool.execute(
      'SELECT '
      '${_uuidHex('u.user_id', 'id')}, '
      'u.username, u.display_name AS full_name, u.is_active, '
      'HEX(u.password_hash) AS password_hash, u.password_alg AS hash_algorithm, '
      'COALESCE(r.role_key, \'staff\') AS role '
      'FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id '
      'WHERE u.user_id = UNHEX(REPLACE(:id, \'-\', \'\')) LIMIT 1',
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
      'UPDATE users SET password_hash = :hash, password_alg = :algorithm '
      'WHERE user_id = UNHEX(REPLACE(:id, \'-\', \'\'))',
      {'hash': hash, 'algorithm': algorithm, 'id': userId},
    );
  }

  // ── Sessions ───────────────────────────────────────────────────────────────

  Future<void> createSession({
    required String sessionId,
    required String userId,
    required String refreshTokenHash,
    required String role,
    required DateTime expiresAt,
  }) async {
    await _pool.execute(
      'INSERT INTO sessions (session_id, user_id, refresh_token_hash, role, expires_at) '
      'VALUES (UNHEX(REPLACE(:sessionId, \'-\', \'\')), '
      'UNHEX(REPLACE(:userId, \'-\', \'\')), '
      ':refreshTokenHash, :role, :expiresAt)',
      {
        'sessionId': sessionId,
        'userId': userId,
        'refreshTokenHash': refreshTokenHash,
        'role': role,
        'expiresAt': _formatDateTime(expiresAt),
      },
    );
    // Stamp last_login_at on the user row.
    await _pool.execute(
      'UPDATE users SET last_login_at = NOW() '
      "WHERE user_id = UNHEX(REPLACE(:userId, '-', ''))",
      {'userId': userId},
    );
  }

  Future<Map<String, dynamic>?> findActiveSession(
      String refreshTokenHash) async {
    final result = await _pool.execute(
      'SELECT '
      '${_uuidHex('s.session_id', 'id')}, '
      '${_uuidHex('s.user_id', 'user_id')}, '
      's.expires_at, s.revoked_at, '
      'u.username, u.display_name AS full_name, u.is_active, '
      'COALESCE(r.role_key, \'staff\') AS role '
      'FROM sessions s '
      'JOIN users u ON s.user_id = u.user_id '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id '
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
      'UPDATE sessions SET revoked_at = NOW() '
      'WHERE session_id = UNHEX(REPLACE(:id, \'-\', \'\'))',
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
      'WHERE user_id = UNHEX(REPLACE(:userId, \'-\', \'\')) AND revoked_at IS NULL',
      {'userId': userId},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) {
    final map = rowToMap(row);
    // password_hash is selected as HEX(...) — decode hex back to the ASCII hash string
    final hexHash = map['password_hash'];
    if (hexHash is String && hexHash.isNotEmpty) {
      map['password_hash'] = String.fromCharCodes(
        List.generate(hexHash.length ~/ 2,
            (i) => int.parse(hexHash.substring(i * 2, i * 2 + 2), radix: 16)),
      );
    }
    return map;
  }

  String _formatDateTime(DateTime dt) =>
      dt.toUtc().toString().replaceFirst('Z', '').substring(0, 19);
}
