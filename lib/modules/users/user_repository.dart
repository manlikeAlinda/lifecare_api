import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class UserRepository {
  final MySQLConnectionPool _pool;

  UserRepository(this._pool);

  static const _selectFields =
      'SELECT '
      '${_uuidId}, '
      'username, email, full_name, role, is_active, created_at, updated_at '
      'FROM users';

  // ignore: constant_identifier_names
  static const _uuidId = "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id";

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? role,
  }) async {
    final where = role != null ? "WHERE role = :role AND is_active = 1" : "WHERE is_active = 1";
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    if (role != null) params['role'] = role;

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM users $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_selectFields $where ORDER BY created_at DESC LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      '$_selectFields WHERE ${uuidWhere('id', 'id')} LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> findByUsername(String username) async {
    final result = await _pool.execute(
      '$_selectFields WHERE username = :username LIMIT 1',
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
    await _pool.execute(
      'INSERT INTO users (id, username, email, full_name, password_hash, hash_algorithm, role) '
      'VALUES (${uuidParam('id')}, :username, :email, :fullName, :passwordHash, :algorithm, :role)',
      {
        'id': id,
        'username': username,
        'email': email,
        'fullName': fullName,
        'passwordHash': passwordHash,
        'algorithm': 'bcrypt',
        'role': role,
      },
    );
    return findById(id) as dynamic;
  }

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
  ) async {
    if (fields.isEmpty) return findById(id);

    final setClauses = fields.keys.map((k) => '$k = :$k').join(', ');
    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.execute(
      'UPDATE users SET $setClauses, updated_at = NOW() '
      'WHERE ${uuidWhere('id', 'id')}',
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
      'UPDATE users SET password_hash = :hash, hash_algorithm = :algorithm, '
      'updated_at = NOW() WHERE ${uuidWhere('id', 'id')}',
      {'hash': passwordHash, 'algorithm': algorithm, 'id': id},
    );
  }

  Future<void> updateRole(String id, String role) async {
    await _pool.execute(
      'UPDATE users SET role = :role, updated_at = NOW() '
      'WHERE ${uuidWhere('id', 'id')}',
      {'role': role, 'id': id},
    );
  }

  Future<void> softDelete(String id) async {
    await _pool.execute(
      'UPDATE users SET is_active = 0, updated_at = NOW() '
      'WHERE ${uuidWhere('id', 'id')}',
      {'id': id},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
