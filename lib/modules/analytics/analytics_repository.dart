import 'package:mysql_client/mysql_client.dart';
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
  Future<List<int>> getDailyCounts({int days = 7}) async {
    final result = await _pool.execute(
      'SELECT DATE(created_at) AS date, COUNT(*) AS cnt '
      'FROM encounters '
      'WHERE created_at >= DATE_SUB(CURDATE(), INTERVAL :days DAY) '
      'GROUP BY DATE(created_at) '
      'ORDER BY date ASC',
      {'days': days},
    );

    // Build a map of date-string → count from DB rows.
    final dbMap = <String, int>{};
    for (final row in result.rows) {
      final r = row.assoc();
      final date = r['date'] ?? '';
      final count = int.tryParse(r['cnt'] ?? '0') ?? 0;
      if (date.isNotEmpty) dbMap[date] = count;
    }

    // Generate the full date range (oldest first), zero-filling missing days.
    final today = DateTime.now();
    final counts = <int>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      counts.add(dbMap[key] ?? 0);
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
      'ORDER BY e.visited_at DESC',
      {'from': from, 'to': to},
    );

    return {
      'report_type': 'encounters',
      'generated_at': DateTime.now().toIso8601String(),
      'period': {'from': from, 'to': to},
      'encounters': result.rows.map((r) => Map<String, dynamic>.from(r.assoc())).toList(),
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
