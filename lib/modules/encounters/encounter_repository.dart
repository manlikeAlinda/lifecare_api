import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart';
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class EncounterRepository {
  final MySQLConnectionPool _pool;

  EncounterRepository(this._pool);

  // ── DB column reality ─────────────────────────────────────────────────────
  // encounters:           encounter_id (PK), patient_id, dependent_id,
  //                       reference_number, service_id, service_type,
  //                       status, total_cost, visited_at, created_at
  // encounter_services:   id (PK), encounter_id, service_id (legacy, unused —
  //                       see migration 025), domain, domain_item_id,
  //                       service_name, price, quantity
  // encounter_medications: id (PK), encounter_id, medication_id (legacy,
  //                        unused), drug_id, dosage_instructions, quantity,
  //                        rate, medication_name
  // wallet_ledger:        ledger_id, wallet_id, type, amount_shillings
  // ─────────────────────────────────────────────────────────────────────────

  static const _uuidCols =
      "LOWER(CONCAT(SUBSTR(HEX(e.encounter_id),1,8),'-',SUBSTR(HEX(e.encounter_id),9,4),'-',"
      "SUBSTR(HEX(e.encounter_id),13,4),'-',SUBSTR(HEX(e.encounter_id),17,4),'-',"
      "SUBSTR(HEX(e.encounter_id),21))) AS id, "
      "LOWER(CONCAT(SUBSTR(HEX(e.patient_id),1,8),'-',SUBSTR(HEX(e.patient_id),9,4),'-',"
      "SUBSTR(HEX(e.patient_id),13,4),'-',SUBSTR(HEX(e.patient_id),17,4),'-',"
      "SUBSTR(HEX(e.patient_id),21))) AS patient_id, "
      "LOWER(CONCAT(SUBSTR(HEX(e.dependent_id),1,8),'-',SUBSTR(HEX(e.dependent_id),9,4),'-',"
      "SUBSTR(HEX(e.dependent_id),13,4),'-',SUBSTR(HEX(e.dependent_id),17,4),'-',"
      "SUBSTR(HEX(e.dependent_id),21))) AS dependent_id";

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? patientId,
    String? dependentId,
    bool excludeDependents = false,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    // True when the caller is the PRIMARY viewing a beneficiary's visits —
    // triggers reason redaction (see _redact). Never set for a beneficiary
    // viewing their own visits (they own the reason) or for staff/admin
    // (out of scope for this spec, which only restricts the primary).
    bool asPrimaryView = false,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    // dependentId scopes to visits recorded FOR that specific beneficiary
    // (e.dependent_id) — used for a beneficiary's own private visit view.
    // patientId alone matches the staff/primary-holder default: every visit
    // on the family account, including beneficiaries' (since those rows
    // still carry the primary's patient_id, just with dependent_id set).
    // excludeDependents narrows that to the primary's own visits only, for
    // the primary's private view (symmetric with a beneficiary's).
    if (dependentId != null) {
      conditions.add("e.dependent_id = UNHEX(REPLACE(:dependentId, '-', ''))");
      params['dependentId'] = dependentId;
    } else if (patientId != null) {
      conditions.add("e.patient_id = UNHEX(REPLACE(:patientId, '-', ''))");
      params['patientId'] = patientId;
      if (excludeDependents) {
        conditions.add('e.dependent_id IS NULL');
      }
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
      'e.status, e.total_cost, e.discount_shillings, e.created_at, e.reason, e.reason_hidden, '
      'p.full_name AS patient_name, p.patient_code, '
      'dep.full_name AS dependent_name, dep.patient_code AS dependent_code, '
      'dep.is_minor AS dependent_is_minor '
      'FROM encounters e '
      'LEFT JOIN patients p ON p.patient_id = e.patient_id '
      'LEFT JOIN patients dep ON dep.patient_id = e.dependent_id '
      '$where '
      'ORDER BY e.visited_at DESC LIMIT :limit OFFSET :offset',
      params,
    );

    final encounters = result.rows.map(_rowToMap).map((e) => _redact(e, asPrimaryView)).toList();

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

  Future<Map<String, dynamic>?> findById(String id, {bool asPrimaryView = false}) async {
    final result = await _pool.execute(
      'SELECT $_uuidCols, e.reference_number, e.visited_at, e.service_type, '
      'e.status, e.total_cost, e.discount_shillings, e.created_at, e.reason, e.reason_hidden, '
      'p.full_name AS patient_name, p.patient_code, '
      'dep.full_name AS dependent_name, dep.patient_code AS dependent_code, '
      'dep.is_minor AS dependent_is_minor '
      'FROM encounters e '
      'LEFT JOIN patients p ON p.patient_id = e.patient_id '
      'LEFT JOIN patients dep ON dep.patient_id = e.dependent_id '
      "WHERE e.encounter_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;

    final encounter = _redact(_rowToMap(result.rows.first), asPrimaryView);

    final svcMap = await _findServicesForIds([id]);
    final medMap = await _findMedicationsForIds([id]);
    encounter['services'] = svcMap[id] ?? [];
    encounter['medications'] = medMap[id] ?? [];
    return encounter;
  }

  /// Redacts `reason` in-place when [asPrimaryView] and the encounter's
  /// reason is hidden — never for a minor dependent (they have no toggle,
  /// so this is defense-in-depth against a stray reason_hidden=1). Keeps
  /// `reason_hidden` in the response either way so the UI can render the
  /// "details withheld" placeholder.
  Map<String, dynamic> _redact(Map<String, dynamic> encounter, bool asPrimaryView) {
    final hidden = encounter['reason_hidden'] == true;
    final dependentIsMinor = encounter['dependent_is_minor'] == true;
    if (asPrimaryView && hidden && !dependentIsMinor) {
      encounter['reason'] = null;
    }
    encounter.remove('dependent_is_minor');
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
      'es.domain, es.domain_item_id, '
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
      'em.drug_id, em.medication_name AS name, em.quantity, '
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

  /// Beneficiary-owned toggle — caller ownership is checked one level up in
  /// EncounterService.setReasonHidden before this is ever called.
  Future<void> setReasonHidden(String id, bool hidden, {required String actorId}) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        "UPDATE encounters SET reason_hidden = :hidden "
        "WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
        {'id': id, 'hidden': hidden ? 1 : 0},
      );
      await writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'ENCOUNTER_REASON_HIDDEN_TOGGLE',
        targetType: 'encounter',
        targetIdUuid: id,
        after: {'reason_hidden': hidden},
      );
    });
  }

  // ── Create ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> create({
    required String encounterId,
    required String patientId,
    String? dependentId,
    required String walletId,
    required double totalCost,
    double discountShillings = 0,
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
      // 1. Insert encounter — include dependent_id when provided.
      await conn.execute(
        'INSERT INTO encounters '
        '(encounter_id, patient_id, dependent_id, reference_number, visited_at, '
        'service_type, total_cost, discount_shillings) '
        "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:patientId, '-', '')), "
        "${dependentId != null ? "UNHEX(REPLACE(:dependentId, '-', ''))" : 'NULL'}, "
        ':referenceNumber, :visitedAt, :serviceType, :totalCost, :discountShillings)',
        {
          'id': encounterId,
          'patientId': patientId,
          if (dependentId != null) 'dependentId': dependentId,
          'referenceNumber': referenceNumber ?? '',
          'visitedAt': visitedAt ?? _nowString(),
          'serviceType': serviceType ?? 'General',
          'totalCost': totalCost,
          'discountShillings': discountShillings.round(),
        },
      );

      // 2. Insert services. domain/domain_item_id/unit_price are already
      // catalog-resolved by EncounterService — never re-derived from client input.
      for (final svc in services) {
        await conn.execute(
          'INSERT INTO encounter_services '
          '(id, encounter_id, domain, domain_item_id, service_name, price, quantity) '
          "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
          ':domain, :domainItemId, :serviceName, :price, :qty)',
          {
            'id': generateUuid(),
            'encId': encounterId,
            'domain': svc['domain'],
            'domainItemId': svc['domain_item_id'],
            'serviceName': svc['service_name'] as String? ?? '',
            'price': svc['unit_price'] as double,
            'qty': svc['quantity'] as int,
          },
        );
      }

      // 3. Insert medications. drug_id/unit_price are already catalog-resolved.
      for (final med in medications) {
        await conn.execute(
          'INSERT INTO encounter_medications '
          '(id, encounter_id, drug_id, dosage_instructions, quantity, '
          'rate, medication_name) '
          "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
          ':drugId, :dosage, :qty, :rate, :medName)',
          {
            'id': generateUuid(),
            'encId': encounterId,
            'drugId': med['drug_id'],
            'dosage': med['dosage_instructions'],
            'qty': med['quantity'] as int,
            'rate': med['unit_price'] as double,
            'medName': med['medication_name'] as String? ?? '',
          },
        );
      }

      // 4. Wallet ledger deduction — encounter_id links this entry back to
      // the visit that caused it (migration 035), so the transaction detail
      // screen can show what the money was for.
      await conn.execute(
        'INSERT INTO wallet_ledger (ledger_id, wallet_id, encounter_id, type, amount_shillings) '
        "VALUES (UNHEX(REPLACE(:ledgerId, '-', '')), "
        "UNHEX(REPLACE(:walletId, '-', '')), "
        "UNHEX(REPLACE(:encounterId, '-', '')), 'deduction', :amount)",
        {
          'ledgerId': ledgerEntryId,
          'walletId': walletId,
          'encounterId': encounterId,
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
        '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':action, :targetType, \'\', '
        ':action, :targetType, '
        "UNHEX(REPLACE(:targetId, '-', '')), '{}')",
        {
          'auditId': generateUuid(),
          'actorId': createdBy,
          'action': 'CREATE_ENCOUNTER',
          'targetType': 'encounter',
          'targetId': encounterId,
        },
      );
    });

    return (await findById(encounterId))!;
  }

  // ── Update ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields,
    String updatedBy, {
    List<Map<String, dynamic>>? newServices,
    List<Map<String, dynamic>>? newMedications,
    double? newTotal,
    double? newDiscount,
    double oldTotal = 0,
    String? walletId,
  }) async {
    // Scalar fields that map directly to DB columns.
    const colMap = {
      'service_type': 'service_type',
      'encounter_type': 'service_type', // legacy alias
      'status': 'status',
      'reference_number': 'reference_number',
      'visited_at': 'visited_at',
    };

    final setClauses = <String>[];
    final params = <String, dynamic>{'id': id};

    for (final key in fields.keys) {
      if (colMap.containsKey(key)) {
        setClauses.add('${colMap[key]} = :$key');
        params[key] = fields[key];
      }
    }

    // If child lines are being replaced, also update total_cost/discount —
    // always set together by EncounterService.updateEncounter, which
    // recomputes both from the same server-resolved line prices.
    if (newTotal != null) {
      setClauses.add('total_cost = :newTotal');
      params['newTotal'] = newTotal;
    }
    if (newDiscount != null) {
      setClauses.add('discount_shillings = :newDiscount');
      params['newDiscount'] = newDiscount.round();
    }

    await _pool.transactional((conn) async {
      if (setClauses.isNotEmpty) {
        await conn.execute(
          'UPDATE encounters SET ${setClauses.join(', ')} '
          "WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
          params,
        );
      }

      // Replace child lines when provided.
      if (newServices != null) {
        await conn.execute(
          'DELETE FROM encounter_services '
          "WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        for (final svc in newServices) {
          await conn.execute(
            'INSERT INTO encounter_services '
            '(id, encounter_id, domain, domain_item_id, service_name, price, quantity) '
            "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
            ':domain, :domainItemId, :serviceName, :price, :qty)',
            {
              'id': generateUuid(),
              'encId': id,
              'domain': svc['domain'],
              'domainItemId': svc['domain_item_id'],
              'serviceName': svc['service_name'] as String? ?? '',
              'price': svc['unit_price'] as double,
              'qty': svc['quantity'] as int,
            },
          );
        }
      }

      if (newMedications != null) {
        await conn.execute(
          'DELETE FROM encounter_medications '
          "WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
          {'id': id},
        );
        for (final med in newMedications) {
          await conn.execute(
            'INSERT INTO encounter_medications '
            '(id, encounter_id, drug_id, dosage_instructions, quantity, '
            'rate, medication_name) '
            "VALUES (UNHEX(REPLACE(:id, '-', '')), UNHEX(REPLACE(:encId, '-', '')), "
            ':drugId, :dosage, :qty, :rate, :medName)',
            {
              'id': generateUuid(),
              'encId': id,
              'drugId': med['drug_id'],
              'dosage': med['dosage_instructions'],
              'qty': med['quantity'] as int,
              'rate': med['unit_price'] as double,
              'medName': med['medication_name'] as String? ?? '',
            },
          );
        }
      }

      // Adjust wallet when total changed. walletId is resolved by the caller
      // via WalletRepository.findByPatientId — never re-derived here with a
      // raw patient_id join, which silently skips beneficiaries whose wallet
      // is keyed to the primary account holder, not their own patient_id.
      if (newTotal != null && walletId != null) {
        final delta = newTotal - oldTotal;
        if (delta != 0) {
          final deltaInt = delta.round().abs();
          final ledgerType = delta > 0 ? 'deduction' : 'reversal';
          await conn.execute(
            'INSERT INTO wallet_ledger (ledger_id, wallet_id, encounter_id, type, amount_shillings) '
            "VALUES (UNHEX(REPLACE(:ledgerId, '-', '')), UNHEX(REPLACE(:walletId, '-', '')), "
            "UNHEX(REPLACE(:encounterId, '-', '')), :type, :amount)",
            {
              'ledgerId': generateUuid(),
              'walletId': walletId,
              'encounterId': id,
              'type': ledgerType,
              'amount': deltaInt,
            },
          );
          final sign = delta > 0 ? '-' : '+';
          await conn.execute(
            'UPDATE wallets SET balance_shillings = balance_shillings $sign :amount, '
            '    last_activity_at = NOW() '
            "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
            {'amount': deltaInt, 'walletId': walletId},
          );
        }
      }

      // Audit log.
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':action, :targetType, \'\', '
        ':action, :targetType, '
        "UNHEX(REPLACE(:targetId, '-', '')), '{}')",
        {
          'auditId': generateUuid(),
          'actorId': updatedBy,
          'action': 'UPDATE_ENCOUNTER',
          'targetType': 'encounter',
          'targetId': id,
        },
      );
    });

    return findById(id);
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Hard-deletes the encounter. Runs inside a transaction:
  /// reverses the wallet ledger deduction, restores the balance,
  /// deletes child rows (via CASCADE), then writes an audit entry.
  /// [walletId] must be resolved by the caller via
  /// WalletRepository.findByPatientId — see EncounterService.deleteEncounter.
  /// A raw join on encounters.patient_id silently misses beneficiaries, whose
  /// wallet is keyed to the primary account holder, not their own patient_id.
  Future<bool> delete(String id, String deletedBy, {String? walletId}) async {
    // Fetch the encounter's total_cost before we delete anything.
    final encResult = await _pool.execute(
      "SELECT total_cost FROM encounters WHERE encounter_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (encResult.rows.isEmpty) return false;

    final encRow = rowToMap(encResult.rows.first);
    final totalCost = (_toDouble(encRow['total_cost'])).round();

    await _pool.transactional((conn) async {
      // 1. Reverse wallet ledger + balance if a wallet exists and cost > 0.
      if (walletId != null && totalCost > 0) {
        await conn.execute(
          'INSERT INTO wallet_ledger (ledger_id, wallet_id, encounter_id, type, amount_shillings) '
          "VALUES (UNHEX(REPLACE(:ledgerId, '-', '')), UNHEX(REPLACE(:walletId, '-', '')), "
          "UNHEX(REPLACE(:encounterId, '-', '')), 'reversal', :amount)",
          {
            'ledgerId': generateUuid(),
            'walletId': walletId,
            'encounterId': id,
            'amount': totalCost,
          },
        );
        await conn.execute(
          'UPDATE wallets SET balance_shillings = balance_shillings + :amount, '
          '    last_activity_at = NOW() '
          "WHERE wallet_id = UNHEX(REPLACE(:walletId, '-', ''))",
          {'amount': totalCost, 'walletId': walletId},
        );
      }

      // 2. Delete encounter (encounter_services + encounter_medications removed via CASCADE).
      await conn.execute(
        "DELETE FROM encounters WHERE encounter_id = UNHEX(REPLACE(:id, '-', ''))",
        {'id': id},
      );

      // 3. Audit log.
      await conn.execute(
        'INSERT INTO audit_log '
        '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':action, :targetType, \'\', '
        ':action, :targetType, '
        "UNHEX(REPLACE(:targetId, '-', '')), '{}')",
        {
          'auditId': generateUuid(),
          'actorId': deletedBy,
          'action': 'DELETE_ENCOUNTER',
          'targetType': 'encounter',
          'targetId': id,
        },
      );
    });

    return true;
  }

  // ── Type helpers ──────────────────────────────────────────────────────────

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _nowString() {
    final now = DateTime.now().toUtc();
    return now.toString().substring(0, 19);
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
