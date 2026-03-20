import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'analytics_service.dart';

class AnalyticsHandler {
  final AnalyticsService _service;

  AnalyticsHandler(this._service);

  Future<Response> getKpis(Request request) async {
    final dateFrom = queryParam(request, 'date_from');
    final dateTo = queryParam(request, 'date_to');
    final kpis = await _service.getKpis(dateFrom: dateFrom, dateTo: dateTo);
    return okResponse(kpis);
  }

  Future<Response> getVisitTrend(Request request) async {
    final dateFrom = queryParam(request, 'date_from');
    final dateTo = queryParam(request, 'date_to');
    final groupBy = queryParam(request, 'group_by') ?? 'day';
    final trend = await _service.getVisitTrend(
      dateFrom: dateFrom,
      dateTo: dateTo,
      groupBy: groupBy,
    );
    return okListResponse(trend, total: trend.length);
  }

  Future<Response> getDepositsHeld(Request request) async {
    final data = await _service.getDepositsHeld();
    return okResponse(data);
  }

  Future<Response> generateReport(Request request) async {
    final body = await parseJsonBody(request);

    Validator(body)
      ..required('type')
      ..oneOf('type', ['summary', 'encounters', 'financial'])
      ..throwIfInvalid();

    final report = await _service.generateReport(body);
    return okResponse(report);
  }
}
