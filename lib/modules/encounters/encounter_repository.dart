import 'dart:convert';
import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class EncounterRepository {
  final MySQLConnectionPool _pool;

  EncounterRepository(this._pool);

  static const _uuidCols =
      "LOWER(CONCAT(SUBSTR(HEX(e.id),1,8),'-',SUBSTR(HEX(e.id),9,4),'-',SUBSTR(HEX(e.id),13,4),'-',SUBSTR(HEX(e.id),17,4),'-',SUBSTR(HEX(e.id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(e.patient_id),1,8),'-',SUBSTR(HEX(e.patient_id),9,4),'-',SUBSTR(HEX(e.patient_id),13,4),'-',SUBSTR(HEX(e.patient_id),17,4),'-',SUBSTR(HEX(e.patient_id),21))) AS patient_id";

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? patientId,
    String? status,
    String? dateFrom,
    String? dateTo,
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
      conditions.add('e.encounter_date >= :dateFrom');
      params['dateFrom'] = dateFrom;
    }
    if (dateTo != null) {
      conditions.add('e.encounter_date <= :dateTo');
      params['dateTo'] = dateTo;
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM encounters e $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT $_uuidCols, e.encounter_number, e.encounter_date, e.encounter_type, '
      'e.provider, e.notes, e.status, e.total_amount, e.created_at, e.updated_at '
      'FROM encounters e $where '
      'ORDER BY e.encounter_date DESC LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      'SELECT $_uuidCols, e.encounter_number, e.encounter_date, e.encounter_type, '
      'e.provider, e.notes, e.status, e.total_amount, e.created_at, e.updated_at '
      'FROM encounters e '
      "WHERE e.id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;

    final encounter = _rowToMap(result.rows.first);

    // Fetch services
    final services = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(es.id),1,8),'-',SUBSTR(HEX(es.id),9,4),'-',SUBSTR(HEX(es.id),13,4),'-',SUBSTR(HEX(es.id),17,4),'-',SUBSTR(HEX(es.id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(es.catalog_item_id),1,8),'-',SUBSTR(HEX(es.catalog_item_id),9,4),'-',SUBSTR(HEX(es.catalog_item_id),13,4),'-',SUBSTR(HEX(es.catalog_item_id),17,4),'-',SUBSTR(HEX(es.catalog_item_id),21))) AS catalog_item_id, "
      'ci.name, es.quantity, es.unit_price, es.total_price, es.notes '
      'FROM encounter_services es '
      'JOIN catalog_items ci ON es.catalog_item_id = ci.id '
      "WHERE es.encounter_id = UNHEX(REPLACE(:id, '-', ''))",
      {'id': id},
    );

    // Fetch medications
    final medications = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(em.id),1,8),'-',SUBSTR(HEX(em.id),9,4),'-',SUBSTR(HEX(em.id),13,4),'-',SUBSTR(HEX(em.id),17,4),'-',SUBSTR(HEX(em.id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(em.catalog_item_id),1,8),'-',SUBSTR(HEX(em.catalog_item_id),9,4),'-',SUBSTR(HEX(em.catalog_item_id),13,4),'-',SUBSTR(HEX(em.catalog_item_id),17,4),'-',SUBSTR(HEX(em.catalog_item_id),21))) AS catalog_item_id, "
      'ci.name, em.quantity, em.unit_price, em.total_price, em.dosage_instructions, em.notes '
      'FROM encounter_medications em '
      'JOIN catalog_items ci ON em.catalog_item_id = ci.id '
      "WHERE em.encounter_id = UNHEX(REPLACE(:id, '-', ''))",
      {'id': id},
    );

    encounter['services'] = services.rows.map(_rowToMap).toList();
    encounter['medications'] = medications.rows.map(_rowToMap).toList();
    return encounter;
  }

  /// Atomic encounter creation: inserts encounter, services, medications,
  /// deducts wallet, and writes audit — all in one transaction.
  Future<Map<String, dynamic>> create({
    required String encounterId,
    required String patientId,
    required String walletId,
    required double totalAmount,
    required double walletBalanceBefore,
    required String createdBy,
    required List<Map<String, dynamic>> services,
    required List<Map<String, dynamic>> medications,
    String? encounterNumber,
    String? encounterType,
    String? provider,
    String? notes,
    String? encounterDate,
  }) async {
    final ledgerEntryId = generateUuid();

    await _pool.transactional((conn) async {
      // 1. Insert encounter
      await conn.execute(
        'INSERT INTO encounters '
        '(id, patient_id, encounter_number, encounter_date, encounter_type, provider, notes, total_amount, wallet_ledger_id, created_by) '
        'VALUES (${uuidParam('id')}, ${uuidParam('patientId')}, :encounterNumber, '
        ':encounterDate, :encounterType, :provider, :notes, :totalAmount, '
        '${uuidParam('ledgerId')}, ${uuidParam('createdBy')})',
        {
          'id': encounterId,
          'patientId': patientId,
          'encounterNumber': encounterNumber,
          'encounterDate': encounterDate ?? _nowString(),
          'encounterType': encounterType,
          'provider': provider,
          'notes': notes,
          'totalAmount': totalAmount,
          'ledgerId': ledgerEntryId,
          'createdBy': createdBy,
        },
      );

      // 2. Insert services
      for (final svc in services) {
        await conn.execute(
          'INSERT INTO encounter_services '
          '(id, encounter_id, catalog_item_id, quantity, unit_price, total_price, notes) '
          'VALUES (${uuidParam('id')}, ${uuidParam('encId')}, ${uuidParam('itemId')}, '
          ':qty, :unitPrice, :totalPrice, :notes)',
          {
            'id': generateUuid(),
            'encId': encounterId,
            'itemId': svc['catalog_item_id'],
            'qty': svc['quantity'] ?? 1,
            'unitPrice': svc['unit_price'],
            'totalPrice': svc['total_price'],
            'notes': svc['notes'],
          },
        );
      }

      // 3. Insert medications
      for (final med in medications) {
        await conn.execute(
          'INSERT INTO encounter_medications '
          '(id, encounter_id, catalog_item_id, quantity, unit_price, total_price, dosage_instructions, notes) '
          'VALUES (${uuidParam('id')}, ${uuidParam('encId')}, ${uuidParam('itemId')}, '
          ':qty, :unitPrice, :totalPrice, :dosage, :notes)',
          {
            'id': generateUuid(),
            'encId': encounterId,
            'itemId': med['catalog_item_id'],
            'qty': med['quantity'] ?? 1,
            'unitPrice': med['unit_price'],
            'totalPrice': med['total_price'],
            'dosage': med['dosage_instructions'],
            'notes': med['notes'],
          },
        );
      }

      // 4. Deduct from wallet ledger (append-only)
      final balanceAfter = walletBalanceBefore - totalAmount;
      await conn.execute(
        'INSERT INTO wallet_ledger '
        '(id, wallet_id, transaction_type, amount, balance_before, balance_after, '
        'reference_type, reference_id, notes, created_by) '
        'VALUES (${uuidParam('ledgerId')}, ${uuidParam('walletId')}, :type, :amount, '
        ':balBefore, :balAfter, :refType, ${uuidParam('refId')}, :notes, ${uuidParam('createdBy')})',
        {
          'ledgerId': ledgerEntryId,
          'walletId': walletId,
          'type': 'deduction',
          'amount': totalAmount,
          'balBefore': walletBalanceBefore,
          'balAfter': balanceAfter,
          'refType': 'encounter',
          'refId': encounterId,
          'notes': 'Encounter billing',
          'createdBy': createdBy,
        },
      );

      // 5. Audit log
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id, details_json) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId, :details)',
        {
          'auditId': generateUuid(),
          'userId': createdBy,
          'action': 'CREATE',
          'targetType': 'encounter',
          'targetId': encounterId,
          'details': jsonEncode({
            'total_amount': totalAmount,
            'services_count': services.length,
            'medications_count': medications.length,
          }),
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
    final allowed = ['provider', 'notes', 'status', 'encounter_type'];
    final setClauses = fields.keys
        .where(allowed.contains)
        .map((k) => '$k = :$k')
        .join(', ');

    if (setClauses.isEmpty) return findById(id);

    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE encounters SET $setClauses, updated_at = NOW() '
        "WHERE id = UNHEX(REPLACE(:id, '-', ''))",
        params,
      );
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId)',
        {
          'auditId': generateUuid(),
          'userId': updatedBy,
          'action': 'UPDATE',
          'targetType': 'encounter',
          'targetId': id,
        },
      );
    });

    return findById(id);
  }

  Future<void> delete(String id, String deletedBy) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'UPDATE encounters SET status = \'cancelled\', updated_at = NOW() '
        "WHERE id = UNHEX(REPLACE(:id, '-', ''))",
        {'id': id},
      );
      await conn.execute(
        'INSERT INTO audit_log (id, user_id, action, target_type, target_id) '
        'VALUES (${uuidParam('auditId')}, ${uuidParam('userId')}, :action, :targetType, :targetId)',
        {
          'auditId': generateUuid(),
          'userId': deletedBy,
          'action': 'DELETE',
          'targetType': 'encounter',
          'targetId': id,
        },
      );
    });
  }

  String _nowString() {
    final now = DateTime.now().toUtc();
    return now.toString().substring(0, 19);
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
