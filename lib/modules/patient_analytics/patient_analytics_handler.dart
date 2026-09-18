import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'patient_analytics_service.dart';

class PatientAnalyticsHandler {
  final PatientAnalyticsService _service;

  PatientAnalyticsHandler(this._service);

  Future<Response> financial(Request request) async {
    final patient = requirePatientUser(request);
    final data = await _service.getFinancial(
      patient.id,
      from: queryParam(request, 'from'),
      to: queryParam(request, 'to'),
    );
    return okResponse(data);
  }

  Future<Response> utilization(Request request) async {
    final patient = requirePatientUser(request);
    final data = await _service.getUtilization(
      patient.id,
      from: queryParam(request, 'from'),
      to: queryParam(request, 'to'),
    );
    return okResponse(data);
  }

  Future<Response> clinical(Request request) async {
    final patient = requirePatientUser(request);
    final data = await _service.getClinical(
      patient.id,
      from: queryParam(request, 'from'),
      to: queryParam(request, 'to'),
    );
    return okResponse(data);
  }

  Future<Response> governance(Request request) async {
    final patient = requirePatientUser(request);
    final data = await _service.getGovernance(
      patient.id,
      from: queryParam(request, 'from'),
      to: queryParam(request, 'to'),
    );
    return okResponse(data);
  }
}
