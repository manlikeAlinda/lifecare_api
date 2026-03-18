import 'package:mysql_client/mysql_client.dart';

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
        'SELECT COUNT(*) as val FROM encounters WHERE encounter_date BETWEEN :from AND :to',
        {'from': from, 'to': to},
      ),
      _sum(
        'SELECT COALESCE(SUM(total_amount), 0) as val FROM encounters WHERE encounter_date BETWEEN :from AND :to',
        {'from': from, 'to': to},
      ),
      _sum(
        'SELECT COALESCE(SUM(amount), 0) as val FROM wallet_ledger '
        'WHERE transaction_type = \'deposit\' AND created_at BETWEEN :from AND :to',
        {'from': from, 'to': to},
      ),
      _count(
        'SELECT COUNT(*) as val FROM patients WHERE is_active = 1',
        {},
      ),
      _count(
        'SELECT COUNT(*) as val FROM encounters WHERE status = \'open\'',
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
      'SELECT DATE_FORMAT(encounter_date, :format) as period, '
      'COUNT(*) as encounter_count, '
      'COALESCE(SUM(total_amount), 0) as total_billed '
      'FROM encounters '
      'WHERE encounter_date BETWEEN :from AND :to '
      'GROUP BY period ORDER BY period ASC',
      {'format': dateFormat, 'from': from, 'to': to},
    );

    return result.rows.map((row) => Map<String, dynamic>.from(row.assoc())).toList();
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

    final topServices = await _pool.execute(
      'SELECT ci.name, ci.category, COUNT(*) as count, '
      'COALESCE(SUM(es.total_price), 0) as total_revenue '
      'FROM encounter_services es '
      'JOIN catalog_items ci ON es.catalog_item_id = ci.id '
      'JOIN encounters e ON es.encounter_id = e.id '
      'WHERE e.encounter_date BETWEEN :from AND :to '
      'GROUP BY ci.id, ci.name, ci.category '
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
          .map((r) => Map<String, dynamic>.from(r.assoc()))
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _generateEncountersReport(
    String from,
    String to,
  ) async {
    final result = await _pool.execute(
      'SELECT '
      "LOWER(CONCAT(SUBSTR(HEX(e.id),1,8),'-',SUBSTR(HEX(e.id),9,4),'-',SUBSTR(HEX(e.id),13,4),'-',SUBSTR(HEX(e.id),17,4),'-',SUBSTR(HEX(e.id),21))) AS id, "
      'e.encounter_number, e.encounter_date, e.encounter_type, e.status, e.total_amount, '
      'CONCAT(p.first_name, \' \', p.last_name) as patient_name, p.patient_number '
      'FROM encounters e '
      'JOIN patients p ON e.patient_id = p.id '
      'WHERE e.encounter_date BETWEEN :from AND :to '
      'ORDER BY e.encounter_date DESC',
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
      'SELECT transaction_type, COUNT(*) as count, '
      'COALESCE(SUM(amount), 0) as total '
      'FROM wallet_ledger '
      'WHERE created_at BETWEEN :from AND :to '
      'GROUP BY transaction_type',
      {'from': from, 'to': to},
    );

    return {
      'report_type': 'financial',
      'generated_at': DateTime.now().toIso8601String(),
      'period': {'from': from, 'to': to},
      'ledger_summary': ledger.rows
          .map((r) => Map<String, dynamic>.from(r.assoc()))
          .toList(),
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
