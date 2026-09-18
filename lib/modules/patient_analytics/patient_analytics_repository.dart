import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

/// Raw data for the corporate portal's analytics dashboard. Every method is
/// scoped to one corporate account — PatientAnalyticsService is responsible
/// for verifying the caller actually owns that account before any of these
/// run.
///
/// Corporate scoping note: a beneficiary's visit still carries the PRIMARY's
/// patient_id (see the long comment on GET /v1/patients/<id>/encounters in
/// app.dart) — `e.patient_id = :corpId` alone already matches every visit on
/// the account, the primary's own and every beneficiary's. `dependent_id`
/// (NULL for the primary's own visits) is only needed to attribute a visit
/// to a specific beneficiary for the per-beneficiary breakdowns below.
class PatientAnalyticsRepository {
  final MySQLConnectionPool _pool;

  PatientAnalyticsRepository(this._pool);

  // ── Financial ──────────────────────────────────────────────────────────

  /// Net spend/deposits for the account's shared wallet in [from, to],
  /// using the same deduction-minus-reversal netting as
  /// AnalyticsRepository.getDashboardKpis, scoped to this account's wallet
  /// instead of the whole clinic.
  Future<Map<String, dynamic>> getWalletTotals(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT '
      "COALESCE(SUM(CASE WHEN wl.type = 'deduction' THEN wl.amount_shillings "
      "WHEN wl.type = 'reversal' THEN -wl.amount_shillings ELSE 0 END), 0) AS net_spend, "
      "COALESCE(SUM(CASE WHEN wl.type = 'deposit' THEN wl.amount_shillings ELSE 0 END), 0) AS total_deposits "
      'FROM wallet_ledger wl '
      "WHERE wl.wallet_id = (SELECT wallet_id FROM wallets "
      "  WHERE COALESCE(primary_patient_id, patient_id) = UNHEX(REPLACE(:corpId, '-', ''))) "
      "AND wl.status = 'posted' "
      'AND wl.created_at >= :from AND wl.created_at <= :to',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return rowToMap(result.rows.first);
  }

  Future<double> getCurrentBalance(String corpId) async {
    final result = await _pool.execute(
      'SELECT balance_shillings FROM wallets '
      "WHERE COALESCE(primary_patient_id, patient_id) = UNHEX(REPLACE(:corpId, '-', ''))",
      {'corpId': corpId},
    );
    if (result.rows.isEmpty) return 0;
    return double.tryParse(result.rows.first.assoc()['balance_shillings'] ?? '0') ?? 0;
  }

  /// One row per beneficiary (or the primary themself, `dependent_id IS
  /// NULL`) with their total spend in the period — the raw material for
  /// both the cost-centre breakdown and the spend percentile/histogram,
  /// which PatientAnalyticsService computes from this.
  Future<List<Map<String, dynamic>>> getSpendByBeneficiary(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT '
      "COALESCE(LOWER(CONCAT(SUBSTR(HEX(e.dependent_id),1,8),'-',SUBSTR(HEX(e.dependent_id),9,4),'-',"
      "SUBSTR(HEX(e.dependent_id),13,4),'-',SUBSTR(HEX(e.dependent_id),17,4),'-',SUBSTR(HEX(e.dependent_id),21))), "
      "'primary') AS beneficiary_id, "
      'COALESCE(owner.full_name, corp.full_name) AS beneficiary_name, '
      "COALESCE(cc.name, 'Unassigned') AS cost_centre_name, "
      "LOWER(CONCAT(SUBSTR(HEX(COALESCE(owner.cost_centre_id, corp.cost_centre_id)),1,8),'-',"
      "SUBSTR(HEX(COALESCE(owner.cost_centre_id, corp.cost_centre_id)),9,4),'-',"
      "SUBSTR(HEX(COALESCE(owner.cost_centre_id, corp.cost_centre_id)),13,4),'-',"
      "SUBSTR(HEX(COALESCE(owner.cost_centre_id, corp.cost_centre_id)),17,4),'-',"
      "SUBSTR(HEX(COALESCE(owner.cost_centre_id, corp.cost_centre_id)),21))) AS cost_centre_id, "
      'COUNT(*) AS encounter_count, '
      'COALESCE(SUM(e.total_cost), 0) AS spend_shillings '
      'FROM encounters e '
      'JOIN patients corp ON corp.patient_id = e.patient_id '
      'LEFT JOIN patients owner ON owner.patient_id = e.dependent_id '
      'LEFT JOIN cost_centres cc ON cc.cost_centre_id = COALESCE(owner.cost_centre_id, corp.cost_centre_id) '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to '
      'GROUP BY beneficiary_id, beneficiary_name, cost_centre_name, cost_centre_id',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getSpendByServiceType(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT e.service_type, COUNT(*) AS count, '
      'COALESCE(SUM(e.total_cost), 0) AS spend_shillings '
      'FROM encounters e '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to '
      'GROUP BY e.service_type ORDER BY spend_shillings DESC',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  Future<double?> getAllocatedBudget(String corpId) async {
    final result = await _pool.execute(
      "SELECT allocated_budget_shillings FROM patients WHERE patient_id = UNHEX(REPLACE(:corpId, '-', ''))",
      {'corpId': corpId},
    );
    if (result.rows.isEmpty) return null;
    final raw = result.rows.first.assoc()['allocated_budget_shillings'];
    return raw == null ? null : double.tryParse(raw);
  }

  // ── Utilization ────────────────────────────────────────────────────────

  Future<int> countRegisteredBeneficiaries(String corpId) async {
    final result = await _pool.execute(
      "SELECT COUNT(*) AS val FROM patients "
      "WHERE primary_account_id = UNHEX(REPLACE(:corpId, '-', '')) AND deleted_at IS NULL",
      {'corpId': corpId},
    );
    return int.parse(result.rows.first.assoc()['val'] ?? '0');
  }

  /// Beneficiaries (+ the primary) with at least one visit in the period.
  Future<int> countActiveBeneficiaries(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT COUNT(DISTINCT COALESCE(e.dependent_id, e.patient_id)) AS val '
      'FROM encounters e '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return int.parse(result.rows.first.assoc()['val'] ?? '0');
  }

  /// One row per beneficiary (+ the primary) with their visit count in the
  /// period — raw material for the visit-frequency distribution.
  Future<List<Map<String, dynamic>>> getVisitCountsByBeneficiary(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT COALESCE(e.dependent_id, e.patient_id) AS beneficiary_key, '
      'COUNT(*) AS visit_count '
      'FROM encounters e '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to '
      'GROUP BY beneficiary_key',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  /// Total spend attributed to dependent_id IS NOT NULL (beneficiaries) vs
  /// IS NULL (the primary themself) — the dependent/primary spend ratio.
  Future<Map<String, dynamic>> getDependentVsPrimarySpend(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT '
      'COALESCE(SUM(CASE WHEN e.dependent_id IS NOT NULL THEN e.total_cost ELSE 0 END), 0) AS dependent_spend, '
      'COALESCE(SUM(CASE WHEN e.dependent_id IS NULL THEN e.total_cost ELSE 0 END), 0) AS primary_spend '
      'FROM encounters e '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return rowToMap(result.rows.first);
  }

  // ── Clinical (aggregate-only — never selects reason/patient_id/dependent_id) ─

  Future<List<Map<String, dynamic>>> getDiagnosisCategoryBreakdown(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT e.diagnosis_category AS category, COUNT(*) AS count '
      'FROM encounters e '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to '
      'AND e.diagnosis_category IS NOT NULL '
      'GROUP BY e.diagnosis_category',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getDrugDispensingTrend(
    String corpId, {
    required String from,
    required String to,
    String groupBy = 'day',
  }) async {
    final dateFormat = switch (groupBy) {
      'month' => '%Y-%m',
      'week' => '%Y-%u',
      _ => '%Y-%m-%d',
    };
    final result = await _pool.execute(
      'SELECT DATE_FORMAT(e.visited_at, :format) AS period, '
      'COALESCE(SUM(em.quantity), 0) AS volume, '
      'COALESCE(SUM(em.rate * em.quantity), 0) AS cost_shillings '
      'FROM encounter_medications em '
      'JOIN encounters e ON e.encounter_id = em.encounter_id '
      "WHERE e.patient_id = UNHEX(REPLACE(:corpId, '-', '')) "
      'AND e.visited_at >= :from AND e.visited_at <= :to '
      'GROUP BY period ORDER BY period ASC',
      {'corpId': corpId, 'from': from, 'to': to, 'format': dateFormat},
    );
    return result.rows.map(rowToMap).toList();
  }

  // ── Governance ─────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAuditActionCounts(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      'SELECT al.action, COUNT(*) AS count FROM audit_log al '
      "WHERE (al.target_id = UNHEX(REPLACE(:corpId, '-', '')) "
      "  OR al.target_id IN (SELECT patient_id FROM patients WHERE primary_account_id = UNHEX(REPLACE(:corpId, '-', '')))) "
      'AND al.timestamp >= :from AND al.timestamp <= :to '
      'GROUP BY al.action ORDER BY count DESC',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  /// Raw rows for PatientAnalyticsService's anomaly rules — kept as simple
  /// fetches with the heuristics themselves in Dart (matching how
  /// AnalyticsRepository.getDailyCounts buckets in Dart rather than SQL),
  /// so the rules stay easy to read and adjust.
  Future<List<Map<String, dynamic>>> getFailedLoginEvents(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      "SELECT al.user_id, al.timestamp FROM audit_log al "
      "WHERE al.action = 'PATIENT_LOGIN_FAIL' "
      "AND (al.user_id = UNHEX(REPLACE(:corpId, '-', '')) "
      "  OR al.user_id IN (SELECT patient_id FROM patients WHERE primary_account_id = UNHEX(REPLACE(:corpId, '-', '')))) "
      'AND al.timestamp >= :from AND al.timestamp <= :to '
      'ORDER BY al.timestamp',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getWalletAdjustments(
    String corpId, {
    required String from,
    required String to,
  }) async {
    final result = await _pool.execute(
      "SELECT wl.created_at, wl.amount_shillings, wl.reason FROM wallet_ledger wl "
      "WHERE wl.type = 'adjustment' "
      "AND wl.wallet_id = (SELECT wallet_id FROM wallets "
      "  WHERE COALESCE(primary_patient_id, patient_id) = UNHEX(REPLACE(:corpId, '-', ''))) "
      'AND wl.created_at >= :from AND wl.created_at <= :to '
      'ORDER BY wl.created_at',
      {'corpId': corpId, 'from': from, 'to': to},
    );
    return result.rows.map(rowToMap).toList();
  }

  /// `ledger_sum` mirrors WalletRepository.appendLedgerEntry's own
  /// credit/debit rule (`deposit`/`refund`/`adjustment`/`opening_balance`
  /// stored as the signed amount and added; everything else subtracted) —
  /// plus `reversal`, which only EncounterRepository ever writes, always as
  /// a positive magnitude that's added back. Must be kept in sync with
  /// those two call sites if either changes.
  Future<Map<String, dynamic>> getWalletReconciliation(String corpId) async {
    final result = await _pool.execute(
      'SELECT w.balance_shillings AS balance, '
      "COALESCE((SELECT SUM(CASE "
      "    WHEN type IN ('deposit', 'refund', 'adjustment', 'opening_balance') THEN amount_shillings "
      "    WHEN type = 'reversal' THEN amount_shillings "
      "    ELSE -amount_shillings END) "
      "  FROM wallet_ledger WHERE wallet_id = w.wallet_id AND status = 'posted'), 0) AS ledger_sum "
      'FROM wallets w '
      "WHERE COALESCE(w.primary_patient_id, w.patient_id) = UNHEX(REPLACE(:corpId, '-', ''))",
      {'corpId': corpId},
    );
    if (result.rows.isEmpty) {
      return {'balance': 0, 'ledger_sum': 0};
    }
    return rowToMap(result.rows.first);
  }
}
