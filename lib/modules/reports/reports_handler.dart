import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'report_logic.dart';
import 'reports_service.dart';

/// /v1/reports/* — all GET, all behind staff auth (see app.dart).
///
/// Access (RolePolicy on the desktop mirrors this): a *general* report —
/// clinic-wide, no `patient_id` — is admin-only; an *individual* report
/// (scoped to one `patient_id`) is available to any staff user. Debtors,
/// new accounts and inactive accounts are general-only, so they're
/// admin-only outright (enforced by the adminOnly pipeline in app.dart).
class ReportsHandler {
  final ReportsService _service;

  ReportsHandler(this._service);

  static const _defaultLimit = 500;
  static const _maxLimit = 1000;

  ClinicDateRange _range(Request r) => parseClinicDateRange(
        queryParam(r, 'from'),
        queryParam(r, 'to'),
        offset: Duration(minutes: AppConfig.clinicTzOffsetMinutes),
      );

  int _offset(Request r) => parseOptionalNonNegativeInt(queryParam(r, 'offset'), 'offset') ?? 0;

  int _limit(Request r) =>
      parseLimit(r, defaultValue: _defaultLimit, max: _maxLimit);

  /// Returns the validated `patient_id`, or null for a general report —
  /// which requires an admin.
  String? _personScope(Request r) {
    final personId = queryParam(r, 'patient_id');
    if (personId == null || personId.isEmpty) {
      if (!requireAuthUser(r).isAdmin) {
        throw ApiError.forbidden('Clinic-wide reports are available to admins only');
      }
      return null;
    }
    Validator({'patient_id': personId})
      ..uuid('patient_id')
      ..throwIfInvalid();
    return personId;
  }

  Future<Response> debtors(Request r) async {
    final from = queryParam(r, 'owing_from');
    final to = queryParam(r, 'owing_to');
    final owingRange = (from == null && to == null)
        ? null
        : parseClinicDateRange(from, to,
            offset: Duration(minutes: AppConfig.clinicTzOffsetMinutes),
            maxDays: 36600);
    return okResponse(await _service.debtors(
      minOwed: parseOptionalNonNegativeInt(queryParam(r, 'min_owed'), 'min_owed'),
      owingRange: owingRange,
      limit: _limit(r),
      offset: _offset(r),
    ));
  }

  Future<Response> deposits(Request r) async {
    final method = queryParam(r, 'method');
    if (method != null) {
      Validator({'method': method})
        // 'bank' is accepted but matches nothing yet: deposits don't record
        // how they were paid, so every deposit classifies as counter or
        // mobile_money (see ReportsRepository._depositMethodSql).
        ..oneOf('method', ['counter', 'mobile_money', 'bank'])
        ..throwIfInvalid();
    }
    return okResponse(await _service.deposits(
      range: _range(r),
      minAmount: parseOptionalNonNegativeInt(queryParam(r, 'min_amount'), 'min_amount'),
      method: method,
      personId: _personScope(r),
      limit: _limit(r),
      offset: _offset(r),
    ));
  }

  Future<Response> newAccounts(Request r) async => okResponse(
        await _service.newAccounts(range: _range(r), limit: _limit(r), offset: _offset(r)),
      );

  Future<Response> inactiveAccounts(Request r) async {
    final months = parseOptionalNonNegativeInt(queryParam(r, 'months'), 'months') ?? 6;
    if (months < 1 || months > 60) {
      throw ApiError.validationError('months must be between 1 and 60');
    }
    return okResponse(await _service.inactiveAccounts(
      months: months,
      limit: _limit(r),
      offset: _offset(r),
    ));
  }

  Future<Response> account(Request r, String patientId) async {
    Validator({'patient_id': patientId})
      ..uuid('patient_id')
      ..throwIfInvalid();
    return okResponse(await _service.account(patientId, _range(r)));
  }

  Future<Response> drugs(Request r) async => okResponse(await _service.drugs(
        range: _range(r),
        drugId: parseOptionalNonNegativeInt(queryParam(r, 'drug_id'), 'drug_id'),
        personId: _personScope(r),
        limit: _limit(r),
        offset: _offset(r),
      ));

  Future<Response> services(Request r) async {
    final domain = queryParam(r, 'domain');
    if (domain != null && !RegExp(r'^[a-z_]{1,20}$').hasMatch(domain)) {
      throw ApiError.validationError('Unknown service domain');
    }
    return okResponse(await _service.services(
      range: _range(r),
      domain: domain,
      itemId: parseOptionalNonNegativeInt(queryParam(r, 'service_id'), 'service_id'),
      personId: _personScope(r),
      limit: _limit(r),
      offset: _offset(r),
    ));
  }
}
