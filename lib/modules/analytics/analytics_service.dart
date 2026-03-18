import 'package:lifecare_api/core/errors/api_error.dart';
import 'analytics_repository.dart';

class AnalyticsService {
  final AnalyticsRepository _repo;

  AnalyticsService(this._repo);

  Future<Map<String, dynamic>> getKpis({
    String? dateFrom,
    String? dateTo,
  }) =>
      _repo.getKpis(dateFrom: dateFrom, dateTo: dateTo);

  Future<List<Map<String, dynamic>>> getVisitTrend({
    String? dateFrom,
    String? dateTo,
    String groupBy = 'day',
  }) {
    const validGroupBy = ['day', 'week', 'month'];
    if (!validGroupBy.contains(groupBy)) {
      throw ApiError.validationError(
        'group_by must be one of: ${validGroupBy.join(', ')}',
      );
    }
    return _repo.getVisitTrend(
      dateFrom: dateFrom,
      dateTo: dateTo,
      groupBy: groupBy,
    );
  }

  Future<Map<String, dynamic>> generateReport(Map<String, dynamic> params) async {
    const validTypes = ['summary', 'encounters', 'financial'];
    final type = params['type'] as String? ?? 'summary';
    if (!validTypes.contains(type)) {
      throw ApiError.validationError(
        'type must be one of: ${validTypes.join(', ')}',
      );
    }
    return _repo.generateReport(params);
  }
}
