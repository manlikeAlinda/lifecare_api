import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class PatientRepository {
  final MySQLConnectionPool _pool;

  PatientRepository(this._pool);

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id";

  static const _selectFields =
      'SELECT $_uuidId, patient_number, first_name, last_name, date_of_birth, '
      'gender, phone, email, address, is_active, created_at, updated_at FROM patients';

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? search,
    bool activeOnly = true,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (activeOnly) conditions.add('is_active = 1');
    if (search != null && search.isNotEmpty) {
      conditions.add(
        '(last_name LIKE :search OR first_name LIKE :search OR patient_number LIKE :search)',
      );
      params['search'] = '%$search%';
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM patients $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_selectFields $where ORDER BY last_name, first_name LIMIT :limit OFFSET :offset',
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

  /// Creates a patient and automatically creates their wallet in the same transaction.
  Future<Map<String, dynamic>> create({
    required String id,
    required String firstName,
    required String lastName,
    required String createdBy,
    required String walletId,
    String? patientNumber,
    String? dateOfBirth,
    String? gender,
    String? phone,
    String? email,
    String? address,
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'INSERT INTO patients '
        '(id, patient_number, first_name, last_name, date_of_birth, gender, phone, email, address, created_by) '
        'VALUES (${uuidParam('id')}, :patientNumber, :firstName, :lastName, '
        ':dateOfBirth, :gender, :phone, :email, :address, ${uuidParam('createdBy')})',
        {
          'id': id,
          'patientNumber': patientNumber,
          'firstName': firstName,
          'lastName': lastName,
          'dateOfBirth': dateOfBirth,
          'gender': gender,
          'phone': phone,
          'email': email,
          'address': address,
          'createdBy': createdBy,
        },
      );

      await conn.execute(
        'INSERT INTO wallets (id, patient_id) VALUES (${uuidParam('walletId')}, ${uuidParam('patientId')})',
        {'walletId': walletId, 'patientId': id},
      );

      // Audit
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id, details_json) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId, :details)',
        {
          'auditId': generateUuid(),
          'userId': createdBy,
          'action': 'CREATE',
          'targetType': 'patient',
          'targetId': id,
          'details': '{"wallet_id":"$walletId"}',
        },
      );
    });

    return (await findById(id))!;
  }

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
    String updatedBy,
  ) async {
    if (fields.isEmpty) return findById(id);

    final allowed = <String>[
      'first_name',
      'last_name',
      'date_of_birth',
      'gender',
      'phone',
      'email',
      'address',
      'patient_number',
    ];
    final setClauses = fields.keys
        .where(allowed.contains)
        .map((k) => '$k = :$k')
        .join(', ');

    if (setClauses.isEmpty) return findById(id);

    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE patients SET $setClauses, updated_at = NOW() '
        'WHERE ${uuidWhere('id', 'id')}',
        params,
      );
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId)',
        {
          'auditId': generateUuid(),
          'userId': updatedBy,
          'action': 'UPDATE',
          'targetType': 'patient',
          'targetId': id,
        },
      );
    });

    return findById(id);
  }

  Future<void> bulkUpdate(
    List<Map<String, dynamic>> updates,
    String updatedBy,
  ) async {
    await _pool.transactional((conn) async {
      for (final update in updates) {
        final id = update['id'] as String;
        final fields = Map<String, dynamic>.from(update)..remove('id');
        final allowed = ['first_name', 'last_name', 'phone', 'email', 'address'];
        final setClauses = fields.keys
            .where(allowed.contains)
            .map((k) => '$k = :$k')
            .join(', ');
        if (setClauses.isEmpty) continue;
        final params = Map<String, dynamic>.from(fields)..['id'] = id;
        await conn.execute(
          'UPDATE patients SET $setClauses, updated_at = NOW() '
          'WHERE ${uuidWhere('id', 'id')}',
          params,
        );
      }
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id, details_json) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId, :details)',
        {
          'auditId': generateUuid(),
          'userId': updatedBy,
          'action': 'BULK_UPDATE',
          'targetType': 'patient',
          'targetId': 'bulk',
          'details': '{"count":${updates.length}}',
        },
      );
    });
  }

  Future<void> softDelete(String id, String deletedBy) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE patients SET is_active = 0, updated_at = NOW() '
        'WHERE ${uuidWhere('id', 'id')}',
        {'id': id},
      );
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId)',
        {
          'auditId': generateUuid(),
          'userId': deletedBy,
          'action': 'DELETE',
          'targetType': 'patient',
          'targetId': id,
        },
      );
    });
  }

  // ── Dependents ──────────────────────────────────────────────────────────────

  static const _depUuidId =
      "LOWER(CONCAT(SUBSTR(HEX(id),1,8),'-',SUBSTR(HEX(id),9,4),'-',SUBSTR(HEX(id),13,4),'-',SUBSTR(HEX(id),17,4),'-',SUBSTR(HEX(id),21))) AS id";

  static const _depPatientId =
      "LOWER(CONCAT(SUBSTR(HEX(patient_id),1,8),'-',SUBSTR(HEX(patient_id),9,4),'-',SUBSTR(HEX(patient_id),13,4),'-',SUBSTR(HEX(patient_id),17,4),'-',SUBSTR(HEX(patient_id),21))) AS patient_id";

  Future<List<Map<String, dynamic>>> findDependents(String patientId) async {
    final result = await _pool.execute(
      'SELECT $_depUuidId, $_depPatientId, first_name, last_name, '
      'date_of_birth, gender, relationship, is_active, created_at, updated_at '
      'FROM dependents WHERE ${uuidWhere('patient_id', 'patientId')} AND is_active = 1 '
      'ORDER BY first_name',
      {'patientId': patientId},
    );
    return result.rows.map(_rowToMap).toList();
  }

  Future<Map<String, dynamic>?> findDependent(
    String patientId,
    String depId,
  ) async {
    final result = await _pool.execute(
      'SELECT $_depUuidId, $_depPatientId, first_name, last_name, '
      'date_of_birth, gender, relationship, is_active, created_at, updated_at '
      'FROM dependents WHERE ${uuidWhere('id', 'id')} AND ${uuidWhere('patient_id', 'patientId')} LIMIT 1',
      {'id': depId, 'patientId': patientId},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>> createDependent({
    required String id,
    required String patientId,
    required String firstName,
    required String lastName,
    String? dateOfBirth,
    String? gender,
    String? relationship,
  }) async {
    await _pool.execute(
      'INSERT INTO dependents (id, patient_id, first_name, last_name, date_of_birth, gender, relationship) '
      'VALUES (${uuidParam('id')}, ${uuidParam('patientId')}, :firstName, :lastName, :dateOfBirth, :gender, :relationship)',
      {
        'id': id,
        'patientId': patientId,
        'firstName': firstName,
        'lastName': lastName,
        'dateOfBirth': dateOfBirth,
        'gender': gender,
        'relationship': relationship,
      },
    );
    return (await findDependent(patientId, id))!;
  }

  Future<Map<String, dynamic>?> updateDependent(
    String patientId,
    String depId,
    Map<String, dynamic> fields,
  ) async {
    final allowed = ['first_name', 'last_name', 'date_of_birth', 'gender', 'relationship'];
    final setClauses = fields.keys
        .where(allowed.contains)
        .map((k) => '$k = :$k')
        .join(', ');
    if (setClauses.isEmpty) return findDependent(patientId, depId);

    final params = Map<String, dynamic>.from(fields)
      ..['id'] = depId
      ..['patientId'] = patientId;

    await _pool.execute(
      'UPDATE dependents SET $setClauses, updated_at = NOW() '
      'WHERE ${uuidWhere('id', 'id')} AND ${uuidWhere('patient_id', 'patientId')}',
      params,
    );
    return findDependent(patientId, depId);
  }

  Future<void> softDeleteDependent(String patientId, String depId) async {
    await _pool.execute(
      'UPDATE dependents SET is_active = 0, updated_at = NOW() '
      'WHERE ${uuidWhere('id', 'id')} AND ${uuidWhere('patient_id', 'patientId')}',
      {'id': depId, 'patientId': patientId},
    );
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
