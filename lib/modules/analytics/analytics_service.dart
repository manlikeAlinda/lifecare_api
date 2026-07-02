import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'analytics_repository.dart';

final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

void _validateDate(String? value, String field) {
  if (value != null && !_dateRe.hasMatch(value)) {
    throw ApiError.validationError('$field must be a date in YYYY-MM-DD format');
  }
}

class AnalyticsService {
  final AnalyticsRepository _repo;

  AnalyticsService(this._repo);

  Future<Map<String, dynamic>> getKpis({
    String? dateFrom,
    String? dateTo,
  }) {
    _validateDate(dateFrom, 'date_from');
    _validateDate(dateTo, 'date_to');
    return _repo.getKpis(dateFrom: dateFrom, dateTo: dateTo);
  }

  Future<List<Map<String, dynamic>>> getVisitTrend({
    String? dateFrom,
    String? dateTo,
    String groupBy = 'day',
  }) {
    _validateDate(dateFrom, 'date_from');
    _validateDate(dateTo, 'date_to');
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

  Future<Map<String, dynamic>> getDepositsHeld() => _repo.getDepositsHeld();

  Future<List<int>> getDailyCounts({int days = 7}) =>
      _repo.getDailyCounts(days: days);

  Future<Map<String, dynamic>> generateReport(
    Map<String, dynamic> params,
    String actorId,
  ) async {
    const validTypes = ['summary', 'encounters', 'financial'];
    final type = params['type'] as String? ?? 'summary';
    if (!validTypes.contains(type)) {
      throw ApiError.validationError(
        'type must be one of: ${validTypes.join(', ')}',
      );
    }
    _validateDate(params['date_from'] as String?, 'date_from');
    _validateDate(params['date_to'] as String?, 'date_to');

    final result = await _repo.generateReport(params);
    await _repo.writeReportAudit(
      actorId: actorId,
      reportType: type,
      auditId: generateUuid(),
    );
    return result;
  }
}
