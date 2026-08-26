import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/utils/clinic_time.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

class AnalyticsRepository {
  final MySQLConnectionPool _pool;

  AnalyticsRepository(this._pool);

  Future<Map<String, dynamic>> getKpis({
    String? dateFrom,
    String? dateTo,
  }) async {
    final from = dateFrom ?? _firstDayOfMonth();
    final to = dateTo ?? _today();

    final results = await Future.wait([
      _count(
        'SELECT COUNT(*) as val FROM patients WHERE created_at BETWEEN :from AND :to AND is_active = 1',
        {'from': from, 'to': to},
      ),
      _count(
        'SELECT COUNT(*) as val FROM encounters WHERE visited_at BETWEEN :from AND :to',
        {'from': from, 'to': to},
      ),
      _sum(
        'SELECT COALESCE(SUM(total_cost), 0) as val FROM encounters WHERE visited_at BETWEEN :from AND :to',
        {'from': from, 'to': to},
      ),
      _sum(
        "SELECT COALESCE(SUM(amount_shillings), 0) as val FROM wallet_ledger "
        "WHERE type = 'deposit' AND created_at BETWEEN :from AND :to",
        {'from': from, 'to': to},
      ),
      _count(
        'SELECT COUNT(*) as val FROM patients WHERE is_active = 1',
        {},
      ),
      _count(
        "SELECT COUNT(*) as val FROM encounters WHERE status != 'cancelled'",
        {},
      ),
    ]);

    return {
      'period': {'from': from, 'to': to},
      'new_patients': results[0],
      'total_encounters': results[1],
      'total_billed': results[2],
      'total_deposits': results[3],
      'active_patients': results[4],
      'open_encounters': results[5],
    };
  }

  /// KPIs for the dashboard Overview page. Unlike [getKpis] (which reports
  /// support with an arbitrary caller-supplied range), this always uses the
  /// clinic's canonical today/month boundaries — one source of truth so a
  /// UI label can never diverge from the query that produced the number.
  /// See ClinicTime for the timezone rationale.
  Future<Map<String, dynamic>> getDashboardKpis() async {
    final todayStart = ClinicTime.sql(ClinicTime.startOfToday());
    final todayEnd   = ClinicTime.sql(ClinicTime.endOfToday());
    final monthStart = ClinicTime.sql(ClinicTime.startOfMonth());
    final now        = ClinicTime.sql(ClinicTime.nowUtc());

    final results = await Future.wait([
      _count(
        'SELECT COUNT(*) as val FROM encounters '
        'WHERE visited_at >= :from AND visited_at < :to',
        {'from': todayStart, 'to': todayEnd},
      ),
      _count(
        'SELECT COUNT(*) as val FROM encounters '
        'WHERE visited_at >= :from AND visited_at <= :to',
        {'from': monthStart, 'to': now},
      ),
      _count(
        'SELECT COUNT(*) as val FROM wallet_ledger '
        'WHERE created_at >= :from AND created_at <= :to',
        {'from': monthStart, 'to': now},
      ),
      // Net revenue = deductions minus reversals in the period. A deleted or
      // downward-edited encounter (EncounterRepository.delete/update) never
      // removes the original 'deduction' row — it inserts a compensating
      // 'reversal' row alongside it — so summing 'deduction' alone counts a
      // deleted visit's charge forever. Reversal is netted against the
      // SAME period it lands in (not retroactively against the original
      // deduction's period), matching normal point-of-sale accounting: a
      // same-day delete zeroes out today's figure; a delete on a later day
      // reduces that later day's figure instead of rewriting history.
      _sum(
        "SELECT COALESCE(SUM(CASE WHEN type = 'deduction' THEN amount_shillings "
        "WHEN type = 'reversal' THEN -amount_shillings ELSE 0 END), 0) as val "
        "FROM wallet_ledger "
        "WHERE type IN ('deduction', 'reversal') AND status = 'posted' "
        'AND created_at >= :from AND created_at < :to',
        {'from': todayStart, 'to': todayEnd},
      ),
      _sum(
        "SELECT COALESCE(SUM(CASE WHEN type = 'deduction' THEN amount_shillings "
        "WHEN type = 'reversal' THEN -amount_shillings ELSE 0 END), 0) as val "
        "FROM wallet_ledger "
        "WHERE type IN ('deduction', 'reversal') AND status = 'posted' "
        'AND created_at >= :from AND created_at <= :to',
        {'from': monthStart, 'to': now},
      ),
      _count(
        // deleted_at IS NULL — a soft-deleted beneficiary (softDeleteSubPatient
        // only sets deleted_at, never flips is_active) must not still count
        // as an active account.
        'SELECT COUNT(*) as val FROM patients '
        'WHERE created_at >= :from AND created_at <= :to '
        'AND is_active = 1 AND deleted_at IS NULL',
        {'from': monthStart, 'to': now},
      ),
      _count(
        'SELECT COUNT(*) as val FROM patients '
        'WHERE is_active = 1 AND deleted_at IS NULL',
        {},
      ),
      _count(
        "SELECT COUNT(*) as val FROM encounters WHERE status != 'cancelled'",
        {},
      ),
      _count(
        'SELECT COUNT(DISTINCT user_id) as val FROM sessions '
        'WHERE revoked_at IS NULL AND expires_at > :now',
        {'now': now},
      ),
      // All-time outstanding balance: computed here (not fetched client-side
      // from GET /v1/wallets, which is paginated to 20 by default) so the
      // dashboard's "Outstanding — ALL TIME" figure is a true total rather
      // than a sum over whatever page of wallets happened to load first.
      _sum(
        "SELECT COALESCE(SUM(-balance_shillings), 0) as val FROM wallets "
        "WHERE balance_shillings < 0 AND status NOT IN ('CLOSED', 'BLOCKED')",
        {},
      ),
    ]);

    return {
      'timezone':                ClinicTime.offsetLabel,
      'generated_at':            DateTime.now().toUtc().toIso8601String(),
      'encounters_today':        results[0],
      'encounters_month':        results[1],
      'transactions_month':      results[2],
      'revenue_today_shillings': results[3],
      'revenue_month_shillings': results[4],
      'new_patients_month':      results[5],
      'active_patients':         results[6],
      'open_encounters':         results[7],
      'active_staff':            results[8],
      'outstanding_shillings':   results[9],
    };
  }

  Future<List<Map<String, dynamic>>> getVisitTrend({
    String? dateFrom,
    String? dateTo,
    String groupBy = 'day',
  }) async {
    final from = dateFrom ?? _thirtyDaysAgo();
    final to = dateTo ?? _today();

    final dateFormat = switch (groupBy) {
      'month' => '%Y-%m',
      'week' => '%Y-%u',
      _ => '%Y-%m-%d',
    };

    final result = await _pool.execute(
      'SELECT DATE_FORMAT(visited_at, :format) as period, '
      'COUNT(*) as encounter_count, '
      'COALESCE(SUM(total_cost), 0) as total_billed '
      'FROM encounters '
      'WHERE visited_at BETWEEN :from AND :to '
      'GROUP BY period ORDER BY period ASC',
      {'format': dateFormat, 'from': from, 'to': to},
    );

    return result.rows.map(rowToMap).toList();
  }

  /// Returns one row per day for the last [days] days (including today),
  /// with zero-filled entries for days that have no encounters.
  ///
  /// Buckets by clinic-local calendar day in Dart rather than MySQL's
  /// DATE()/CURDATE() — those reflect the DB server's own session
  /// timezone, which is a different (and untracked) thing from the
  /// clinic's configured offset. Doing the bucketing here keeps the one
  /// definition of "day" (ClinicTime) authoritative everywhere.
  Future<List<int>> getDailyCounts({int days = 7}) async {
    final todayClinicDate = ClinicTime.clinicDateOf(ClinicTime.nowUtc());
    final oldestClinicDate = todayClinicDate.subtract(Duration(days: days - 1));
    final lowerBoundUtc = oldestClinicDate.subtract(
      Duration(minutes: AppConfig.clinicTzOffsetMinutes),
    );

    final result = await _pool.execute(
      'SELECT visited_at FROM encounters WHERE visited_at >= :from',
      {'from': ClinicTime.sql(lowerBoundUtc)},
    );

    final counts = List<int>.filled(days, 0);
    for (final row in result.rows) {
      final raw = row.assoc()['visited_at'];
      if (raw == null) continue;
      final visitedUtc = DateTime.parse(raw).toUtc();
      final visitedClinicDate = ClinicTime.clinicDateOf(visitedUtc);
      final dayIndex = visitedClinicDate.difference(oldestClinicDate).inDays;
      if (dayIndex >= 0 && dayIndex < days) counts[dayIndex]++;
    }
    return counts;
  }

  Future<Map<String, dynamic>> generateReport(Map<String, dynamic> params) async {
    final reportType = params['type'] as String? ?? 'summary';
    final dateFrom = params['date_from'] as String? ?? _firstDayOfMonth();
    final dateTo = params['date_to'] as String? ?? _today();

    return switch (reportType) {
      'summary' => _generateSummaryReport(dateFrom, dateTo),
      'encounters' => _generateEncountersReport(dateFrom, dateTo),
      'financial' => _generateFinancialReport(dateFrom, dateTo),
      _ => throw ArgumentError('Unknown report type: $reportType'),
    };
  }

  Future<Map<String, dynamic>> _generateSummaryReport(
    String from,
    String to,
  ) async {
    final kpis = await getKpis(dateFrom: from, dateTo: to);
    final trend = await getVisitTrend(dateFrom: from, dateTo: to);

    // Use denormalized service_name from encounter_services — no catalog JOIN.
    final topServices = await _pool.execute(
      'SELECT es.service_name AS name, COUNT(*) as count, '
      'COALESCE(SUM(es.price * es.quantity), 0) as total_revenue '
      'FROM encounter_services es '
      'JOIN encounters e ON es.encounter_id = e.encounter_id '
      'WHERE e.visited_at BETWEEN :from AND :to '
      'GROUP BY es.service_name '
      'ORDER BY count DESC LIMIT 10',
      {'from': from, 'to': to},
    );

    return {
      'report_type': 'summary',
      'generated_at': DateTime.now().toIso8601String(),
      'period': {'from': from, 'to': to},
      'kpis': kpis,
      'visit_trend': trend,
      'top_services': topServices.rows
          .map(rowToMap)
          .toList(),
    };
  }

  static const _encountersReportLimit = 5000;

  Future<Map<String, dynamic>> _generateEncountersReport(
    String from,
    String to,
  ) async {
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(e.encounter_id),1,8),'-',SUBSTR(HEX(e.encounter_id),9,4),'-',"
      "SUBSTR(HEX(e.encounter_id),13,4),'-',SUBSTR(HEX(e.encounter_id),17,4),'-',"
      "SUBSTR(HEX(e.encounter_id),21))) AS id, "
      'e.reference_number, e.visited_at, e.service_type, e.status, e.total_cost, '
      'p.full_name as patient_name, p.patient_code '
      'FROM encounters e '
      'JOIN patients p ON e.patient_id = p.patient_id '
      'WHERE e.visited_at BETWEEN :from AND :to '
      'ORDER BY e.visited_at DESC '
      'LIMIT :limit',
      {'from': from, 'to': to, 'limit': _encountersReportLimit},
    );

    final rows = result.rows.map((r) => Map<String, dynamic>.from(r.assoc())).toList();
    return {
      'report_type': 'encounters',
      'generated_at': DateTime.now().toIso8601String(),
      'period': {'from': from, 'to': to},
      'encounters': rows,
      if (rows.length >= _encountersReportLimit)
        'truncated': true,
    };
  }

  Future<Map<String, dynamic>> _generateFinancialReport(
    String from,
    String to,
  ) async {
    final ledger = await _pool.execute(
      'SELECT type AS transaction_type, COUNT(*) as count, '
      'COALESCE(SUM(amount_shillings), 0) as total '
      'FROM wallet_ledger '
      'WHERE created_at BETWEEN :from AND :to '
      'GROUP BY type',
      {'from': from, 'to': to},
    );

    return {
      'report_type': 'financial',
      'generated_at': DateTime.now().toIso8601String(),
      'period': {'from': from, 'to': to},
      'ledger_summary': ledger.rows
          .map(rowToMap)
          .toList(),
    };
  }

  /// Per-primary beneficiary login-access status counts, for the desktop
  /// admin's aggregate view. Deliberately reads only `patients` — no visit
  /// content, no medical reasons, nothing from `encounters`.
  Future<Map<String, dynamic>> getBeneficiaryLoginStats() async {
    final totals = await _pool.execute(
      "SELECT login_access_status, COUNT(*) as val FROM patients "
      "WHERE account_type = 'dependent' AND deleted_at IS NULL "
      'GROUP BY login_access_status',
      {},
    );
    final byStatus = <String, int>{
      'no_login': 0, 'pending': 0, 'active': 0, 'suspended': 0, 'expired': 0,
    };
    for (final row in totals.rows) {
      final r = row.assoc();
      final status = r['login_access_status'];
      if (status != null && byStatus.containsKey(status)) {
        byStatus[status] = int.tryParse(r['val'] ?? '0') ?? 0;
      }
    }

    final perPrimary = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(b.primary_account_id),1,8),'-',SUBSTR(HEX(b.primary_account_id),9,4),'-',"
      "SUBSTR(HEX(b.primary_account_id),13,4),'-',SUBSTR(HEX(b.primary_account_id),17,4),'-',"
      "SUBSTR(HEX(b.primary_account_id),21))) AS primary_id, "
      'p.full_name AS primary_name, p.patient_code AS primary_code, '
      'COUNT(*) AS beneficiary_count, '
      "SUM(b.login_access_status = 'pending') AS pending_count, "
      "SUM(b.login_access_status = 'active') AS active_count, "
      "SUM(b.login_access_status = 'suspended') AS suspended_count, "
      "SUM(b.login_access_status = 'expired') AS expired_count "
      'FROM patients b '
      'JOIN patients p ON p.patient_id = b.primary_account_id '
      "WHERE b.account_type = 'dependent' AND b.deleted_at IS NULL "
      'GROUP BY b.primary_account_id, p.full_name, p.patient_code '
      'ORDER BY p.full_name',
      {},
    );

    return {
      'totals': byStatus,
      'by_primary': perPrimary.rows.map(rowToMap).toList(),
    };
  }

  Future<Map<String, dynamic>> getDepositsHeld() async {
    final result = await _pool.execute(
      "SELECT COALESCE(SUM(balance_shillings), 0) AS deposits_held, "
      "COUNT(*) AS wallet_count "
      "FROM wallets WHERE status = 'ACTIVE'",
      {},
    );
    final row = result.rows.first.assoc();
    return {
      'deposits_held': double.tryParse(row['deposits_held'] ?? '0') ?? 0.0,
      'wallet_count': int.tryParse(row['wallet_count'] ?? '0') ?? 0,
    };
  }

  Future<void> writeReportAudit({
    required String actorId,
    required String reportType,
    required String auditId,
  }) async {
    try {
      await _pool.execute(
        'INSERT INTO audit_log (audit_id, user_id, actor_user_id, action_type, entity_type, request_id, action, target_type, target_id, details) '
        "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:actorId, '-', '')), "
        "UNHEX(REPLACE(:actorId, '-', '')), "
        ':action, :targetType, \'\', '
        ':action, :targetType, NULL, :details)',
        {
          'auditId': auditId,
          'actorId': actorId,
          'action': 'GENERATE_REPORT',
          'targetType': 'report',
          'details': '{"report_type":"$reportType"}',
        },
      );
    } catch (e) {
      log.warning('Analytics audit write failed: $e');
    }
  }

  Future<int> _count(String sql, Map<String, dynamic> params) async {
    final result = await _pool.execute(sql, params);
    return int.parse(result.rows.first.assoc()['val'] ?? '0');
  }

  Future<double> _sum(String sql, Map<String, dynamic> params) async {
    final result = await _pool.execute(sql, params);
    return double.parse(result.rows.first.assoc()['val'] ?? '0');
  }

  String _today() => DateTime.now().toIso8601String().substring(0, 10);

  String _firstDayOfMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
  }

  String _thirtyDaysAgo() {
    final d = DateTime.now().subtract(const Duration(days: 30));
    return d.toIso8601String().substring(0, 10);
  }
}
