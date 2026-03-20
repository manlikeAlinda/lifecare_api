import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

class UserRepository {
  final MySQLConnectionPool _pool;

  UserRepository(this._pool);

  // Real DB columns: user_id (PK), username, display_name, email, phone_e164,
  // password_hash (varbinary), password_alg, is_active, created_at
  // Role is managed via user_roles + roles join table.

  static String _uuidHex(String col, [String? alias]) {
    final a = alias ?? col;
    return "LOWER(CONCAT(SUBSTR(HEX($col),1,8),'-',SUBSTR(HEX($col),9,4),'-',"
        "SUBSTR(HEX($col),13,4),'-',SUBSTR(HEX($col),17,4),'-',"
        "SUBSTR(HEX($col),21))) AS $a";
  }

  static const _selectFields = 'SELECT '
      "${_uuidHex_u_id}, "
      'u.username, u.display_name AS full_name, u.email, u.is_active, u.created_at, '
      "COALESCE(r.role_key, 'staff') AS role "
      'FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id';

  // Dart doesn't support non-trivial expressions in const, so we build the
  // SELECT inline in each method instead. The constant above is just for reference.

  static const _uuidHex_u_id =
      "LOWER(CONCAT(SUBSTR(HEX(u.user_id),1,8),'-',SUBSTR(HEX(u.user_id),9,4),'-',"
      "SUBSTR(HEX(u.user_id),13,4),'-',SUBSTR(HEX(u.user_id),17,4),'-',"
      "SUBSTR(HEX(u.user_id),21))) AS id";

  static const _baseSelect = 'SELECT '
      "$_uuidHex_u_id, "
      "u.username, u.display_name AS full_name, u.email, u.is_active, u.created_at, "
      "COALESCE(r.role_key, 'staff') AS role "
      'FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id';

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? role,
  }) async {
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    String where;
    if (role != null) {
      where = "WHERE r.role_key = :role AND u.is_active = 1";
      params['role'] = role;
    } else {
      where = "WHERE u.is_active = 1";
    }

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM users u '
      'LEFT JOIN user_roles ur ON ur.user_id = u.user_id '
      'LEFT JOIN roles r ON r.role_id = ur.role_id '
      '$where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_baseSelect $where ORDER BY u.created_at DESC LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      '$_baseSelect WHERE u.user_id = UNHEX(REPLACE(:id, \'-\', \'\')) LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByUsername(String username) async {
    final result = await _pool.execute(
      '$_baseSelect WHERE u.username = :username LIMIT 1',
      {'username': username},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>> create({
    required String id,
    required String username,
    required String fullName,
    required String passwordHash,
    String role = 'staff',
    String? email,
  }) async {
    await _pool.transactional((conn) async {
      // Insert the user
      await conn.execute(
        "INSERT INTO users (user_id, username, email, display_name, password_hash, password_alg) "
        "VALUES (UNHEX(REPLACE(:id, '-', '')), :username, :email, :fullName, :passwordHash, 'bcrypt')",
        {
          'id': id,
          'username': username,
          'email': email,
          'fullName': fullName,
          'passwordHash': passwordHash,
        },
      );

      // Assign role via user_roles join table
      await conn.execute(
        'INSERT INTO user_roles (user_id, role_id, assigned_by) '
        "SELECT UNHEX(REPLACE(:id, '-', '')), role_id, UNHEX(REPLACE(:id, '-', '')) "
        "FROM roles WHERE role_key = :role LIMIT 1",
        {'id': id, 'role': role},
      );
    });
    return (await findById(id))!;
  }

  Future<List<Map<String, dynamic>>> getRoles() async {
    final result = await _pool.execute(
      'SELECT role_key AS id, role_name AS name FROM roles ORDER BY role_name',
      {},
    );
    return result.rows.map((r) => Map<String, dynamic>.from(r.assoc())).toList();
  }

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
  ) async {
    if (fields.isEmpty) return findById(id);

    // Map API field names to real DB column names
    final colMap = <String, String>{
      'full_name': 'display_name',
      'email': 'email',
      'is_active': 'is_active',
    };

    final setClauses = fields.keys
        .where(colMap.containsKey)
        .map((k) => '${colMap[k]} = :$k')
        .join(', ');

    if (setClauses.isEmpty) return findById(id);

    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.execute(
      "UPDATE users SET $setClauses WHERE user_id = UNHEX(REPLACE(:id, '-', ''))",
      params,
    );
    return findById(id);
  }

  Future<void> updatePassword(
    String id,
    String passwordHash,
    String algorithm,
  ) async {
    await _pool.execute(
      'UPDATE users SET password_hash = :hash, password_alg = :algorithm '
      "WHERE user_id = UNHEX(REPLACE(:id, '-', ''))",
      {'hash': passwordHash, 'algorithm': algorithm, 'id': id},
    );
  }

  Future<void> updateRole(String id, String role) async {
    // Update or insert the user's role in user_roles
    await _pool.execute(
      'INSERT INTO user_roles (user_id, role_id, assigned_by) '
      "SELECT UNHEX(REPLACE(:id, '-', '')), role_id, UNHEX(REPLACE(:id, '-', '')) "
      'FROM roles WHERE role_key = :role LIMIT 1 '
      'ON DUPLICATE KEY UPDATE role_id = VALUES(role_id)',
      {'id': id, 'role': role},
    );
  }

  Future<void> softDelete(String id) async {
    await _pool.execute(
      'UPDATE users SET is_active = 0 '
      "WHERE user_id = UNHEX(REPLACE(:id, '-', ''))",
      {'id': id},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
