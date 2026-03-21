import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class EncounterRepository {
  final MySQLConnectionPool _pool;

  EncounterRepository(this._pool);

  // ── DB column reality ─────────────────────────────────────────────────────
  // encounters:           encounter_id (PK), patient_id, dependent_id,
  //                       reference_number, service_id, service_type,
  //                       status, total_cost, visited_at, created_at
  // encounter_services:   id (PK), encounter_id, service_id, service_name,
  //                       price, quantity
  // encounter_medications: id (PK), encounter_id, medication_id, drug_id,
  //                        dosage_instructions, quantity, rate, medication_name
  // ─────────────────────────────────────────────────────────────────────────

  static const _uuidCols =
      "LOWER(CONCAT(SUBSTR(HEX(e.encounter_id),1,8),'-',SUBSTR(HEX(e.encounter_id),9,4),'-',"
      "SUBSTR(HEX(e.encounter_id),13,4),'-',SUBSTR(HEX(e.encounter_id),17,4),'-',"
      "SUBSTR(HEX(e.encounter_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(e.patient_id),1,8),'-',SUBSTR(HEX(e.patient_id),9,4),'-',"
      "SUBSTR(HEX(e.patient_id),13,4),'-',SUBSTR(HEX(e.patient_id),17,4),'-',"
      "SUBSTR(HEX(e.patient_id),21))) AS patient_id";

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? patientId,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (patientId != null) {
      conditions.add("e.patient_id = UNHEX(REPLACE(:patientId, '-', ''))");
      params['patientId'] = patientId;
    }
    if (status != null) {
      conditions.add('e.status = :status');
      params['status'] = status;
    }
    if (dateFrom != null) {
      conditions.add('e.visited_at >= :dateFrom');
      params['dateFrom'] = dateFrom;
    }
    if (dateTo != null) {
      conditions.add('e.visited_at <= :dateTo');
      params['dateTo'] = dateTo;
    }
    if (search != null && search.isNotEmpty) {
      conditions.add(
        '(p.full_name LIKE :search OR e.reference_number LIKE :search OR e.service_type LIKE :search)',
      );
      params['search'] = '%$search%';
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM encounters e '
      'LEFT JOIN patients p ON p.patient_id = e.patient_id '
      '$where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT $_uuidCols, e.reference_number, e.visited_at, e.service_type, '
      'e.status, e.total_cost, e.created_at, '
      'p.full_name AS patient_name, p.patient_code '
      'FROM encounters e '
      'LEFT JOIN patients p ON p.patient_id = e.patient_id '
      '$where '
      'ORDER BY e.visited_at DESC LIMIT :limit OFFSET :offset',
      params,
    );

    final encounters = result.rows.map(_rowToMap).toList();

    // Batch-fetch services and medications for the listed encounters.
    if (encounters.isNotEmpty) {
      final ids = encounters.map((e) => e['id'] as String).toList();
      final svcMap = await _findServicesForIds(ids);
      final medMap = await _findMedicationsForIds(ids);
      for (final enc in encounters) {
        final id = enc['id'] as String;
        enc['services'] = svcMap[id] ?? [];
        enc['medications'] = medMap[id] ?? [];
      }
    }

    return (encounters, total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      'SELECT $_uuidCols, e.reference_number, e.visited_at, e.service_type, '
      'e.status, e.total_cost, e.created_at, '
      'p.full_name AS patient_name, p.patient_code '
      'FROM encounters e '
      'LEFT JOIN patients p ON p.patient_id = e.patient_id '
      "WHERE e.encounter_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;

    final encounter = _rowToMap(result.rows.first);

    final svcMap = await _findServicesForIds([id]);
    final medMap = await _findMedicationsForIds([id]);
    encounter['services'] = svcMap[id] ?? [];
    encounter['medications'] = medMap[id] ?? [];
    return encounter;
  }

  // ── Batch helpers ─────────────────────────────────────────────────────────

  Future<Map<String, List<Map<String, dynamic>>>> _findServicesForIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return {};
    final params = <String, dynamic>{};
    final placeholders = <String>[];
    for (var i = 0; i < ids.length; i++) {
      params['eid$i'] = ids[i];
      placeholders.add("UNHEX(REPLACE(:eid$i, '-', ''))");
    }
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(es.encounter_id),1,8),'-',SUBSTR(HEX(es.encounter_id),9,4),'-',"
      "SUBSTR(HEX(es.encounter_id),13,4),'-',SUBSTR(HEX(es.encounter_id),17,4),'-',"
      "SUBSTR(HEX(es.encounter_id),21))) AS encounter_id, "
      "LOWER(CONCAT(SUBSTR(HEX(es.id),1,8),'-',SUBSTR(HEX(es.id),9,4),'-',"
      "SUBSTR(HEX(es.id),13,4),'-',SUBSTR(HEX(es.id),17,4),'-',"
      "SUBSTR(HEX(es.id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(es.service_id),1,8),'-',SUBSTR(HEX(es.service_id),9,4),'-',"
      "SUBSTR(HEX(es.service_id),13,4),'-',SUBSTR(HEX(es.service_id),17,4),'-',"
      "SUBSTR(HEX(es.service_id),21))) AS service_id, "
      'es.service_name AS name, es.quantity, es.price AS unit_price, '
      '(es.price * es.quantity) AS total_price '
      'FROM encounter_services es '
      'WHERE es.encounter_id IN (${placeholders.join(', ')})',
      params,
    );
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in result.rows) {
      final r = _rowToMap(row);
      final encId = r.remove('encounter_id') as String;
      map.putIfAbsent(encId, () => []).add(r);
    }
    return map;
  }

  Future<Map<String, List<Map<String, dynamic>>>> _findMedicationsForIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return {};
    final params = <String, dynamic>{};
    final placeholders = <String>[];
    for (var i = 0; i < ids.length; i++) {
      params['mid$i'] = ids[i];
      placeholders.add("UNHEX(REPLACE(:mid$i, '-', ''))");
    }
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(em.encounter_id),1,8),'-',SUBSTR(HEX(em.encounter_id),9,4),'-',"
      "SUBSTR(HEX(em.encounter_id),13,4),'-',SUBSTR(HEX(em.encounter_id),17,4),'-',"
      "SUBSTR(HEX(em.encounter_id),21))) AS encounter_id, "
      "LOWER(CONCAT(SUBSTR(HEX(em.id),1,8),'-',SUBSTR(HEX(em.id),9,4),'-',"
      "SUBSTR(HEX(em.id),13,4),'-',SUBSTR(HEX(em.id),17,4),'-',"
      "SUBSTR(HEX(em.id),21))) AS id, "
      'em.medication_name AS name, em.quantity, '
      'em.rate AS unit_price, (em.rate * em.quantity) AS total_price, '
      'em.dosage_instructions '
      'FROM encounter_medications em '
      'WHERE em.encounter_id IN (${placeholders.join(', ')})',
      params,
    );
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in result.rows) {
      final r = _rowToMap(row);
      final encId = r.remove('encounter_id') as String;
      map.putIfAbsent(encId, () => []).add(r);
    }
    return map;
  }

  // ── Create ────────────────────────────────────────────────────────────────

  /// Atomic encounter creation: inserts encounter, services, medications,
  /// deducts wallet ledger, updates wallet balance, writes audit — one tx.
  Future<Map<String, dynamic>> create({
    required String encounterId,
    required String patientId,
    required String walletId,
    required double totalCost,
    required String createdBy,
    required List<Map<String, dynamic>> services,
    required List<Map<String, dynamic>> medications,
    String? referenceNumber,
    String? serviceType,
    String? visitedAt,
  }) async {
    final totalCostInt = totalCost.round();
    final ledgerEntryId = generateUuid();

    await _pool.transactional((conn) async {
      // 1. Insert encounter.
      await conn.execute(
        'INSERT INTO encounters '
        '(encounter_id, patient_id, reference_number, visited_at, service_type, '
        'total_cost) '
        "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:patientId, '-', '')), "
        ':referenceNumber, :visitedAt, :serviceType, :totalCost)',
        {
          'id': encounterId,
          'patientId': patientId,
          'referenceNumber': referenceNumber ?? '',
          'visitedAt': visitedAt ?? _nowString(),
          'serviceType': serviceType ?? 'General',
          'totalCost': totalCost,
        },
      );

      // 2. Insert services.
      for (final svc in services) {
        final rawId = svc['catalog_item_id'] ?? svc['service_id'];
        final serviceId = _toUuidString(rawId) ?? '00000000-0000-0000-0000-000000000000';
        await conn.execute(
          'INSERT INTO encounter_services '
          '(id, encounter_id, service_id, service_name, price, quantity) '
          "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
          "UNHEX(REPLACE(:serviceId, '-', '')), :serviceName, :price, :qty)",
          {
            'id': generateUuid(),
            'encId': encounterId,
            'serviceId': serviceId,
            'serviceName': svc['service_name'] as String? ?? svc['name'] as String? ?? '',
            'price': _toDouble(svc['unit_price'] ?? svc['price']),
            'qty': _toInt(svc['quantity'] ?? 1),
          },
        );
      }

      // 3. Insert medications.
      for (final med in medications) {
        final rawMedId = med['catalog_item_id'] ?? med['medication_id'];
        final medId = _toUuidString(rawMedId);
        await conn.execute(
          'INSERT INTO encounter_medications '
          '(id, encounter_id, medication_id, dosage_instructions, quantity, '
          'rate, medication_name) '
          "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
          "${medId != null ? "UNHEX(REPLACE(:medId, '-', ''))" : 'NULL'}, "
          ':dosage, :qty, :rate, :medName)',
          {
            'id': generateUuid(),
            'encId': encounterId,
            if (medId != null) 'medId': medId,
            'dosage': med['dosage_instructions'],
            'qty': _toInt(med['quantity'] ?? 1),
            'rate': _toDouble(med['unit_price'] ?? med['rate']),
            'medName':
                med['medication_name'] as String? ?? med['name'] as String? ?? '',
          },
        );
      }

      // 4. Append wallet ledger entry (deduction).
      await conn.execute(
        'INSERT INTO wallet_ledger (ledger_id, wallet_id, type, amount_shillings) '
        "VALUES (UNHEX(REPLACE(:ledgerId, '-', '')), "
        "UNHEX(REPLACE(:walletId, '-', '')), 'deduction', :amount)",
        {
          'ledgerId': ledgerEntryId,
          'walletId': walletId,
          'amount': totalCostInt,
        },
      );

      // 5. Update wallet balance (denormalised).
      await conn.execute(
        'UPDATE wallets '
        'SET balance_shillings = balance_shillings - :amount, '
        '    last_activity_at = NOW() '
        "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
        {'amount': totalCostInt, 'walletId': walletId},
      );

      // 6. Audit log.
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, actor_user_id, action_type, entity_type, entity_id, request_id) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':actionType, :entityType, '
        "UNHEX(REPLACE(:entityId, '-', '')), :requestId)",
        {
          'auditId': generateUuid(),
          'actorId': createdBy,
          'actionType': 'CREATE_ENCOUNTER',
          'entityType': 'encounter',
          'entityId': encounterId,
          'requestId': generateUuid(),
        },
      );
    });

    return (await findById(encounterId))!;
  }

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
    String updatedBy,
  ) async {
    // Map API field names to DB columns.
    const colMap = {
      'service_type': 'service_type',
      'encounter_type': 'service_type', // legacy alias accepted
      'status': 'status',
    };

    final setClauses = fields.keys
        .where(colMap.containsKey)
        .map((k) => '${colMap[k]} = :$k')
        .join(', ');

    if (setClauses.isEmpty) return findById(id);

    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE encounters SET $setClauses '
        "WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
        params,
      );
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, actor_user_id, action_type, entity_type, entity_id, request_id) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':actionType, :entityType, '
        "UNHEX(REPLACE(:entityId, '-', '')), :requestId)",
        {
          'auditId': generateUuid(),
          'actorId': updatedBy,
          'actionType': 'UPDATE_ENCOUNTER',
          'entityType': 'encounter',
          'entityId': id,
          'requestId': generateUuid(),
        },
      );
    });

    return findById(id);
  }

  /// Hard-deletes the encounter row. Child rows in encounter_services,
  /// encounter_medications, and encounter_drugs are removed by ON DELETE CASCADE.
  /// Returns true if a row was deleted, false if the encounter was not found.
  Future<bool> delete(String id) async {
    final result = await _pool.execute(
      "DELETE FROM encounters WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
      {'id': id},
    );
    return result.affectedRows.toInt() > 0;
  }

  // ── Type helpers ──────────────────────────────────────────────────────────

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  static int _toInt(dynamic v) {
    if (v == null) return 1;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 1;
    return 1;
  }

  /// Returns v as a UUID string if it looks like one, null otherwise.
  static String? _toUuidString(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    // Accept 32 hex chars with optional dashes (UUID format)
    final stripped = s.replaceAll('-', '');
    if (stripped.length == 32 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(stripped)) {
      // Re-format as UUID if not already
      if (s.contains('-')) return s;
      return '${stripped.substring(0, 8)}-${stripped.substring(8, 12)}-'
          '${stripped.substring(12, 16)}-${stripped.substring(16, 20)}-'
          '${stripped.substring(20)}';
    }
    return null; // INT pk or invalid — fall back to zero UUID at call site
  }

  String _nowString() {
    final now = DateTime.now().toUtc();
    return now.toString().substring(0, 19);
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
