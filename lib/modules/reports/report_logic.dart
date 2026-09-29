import 'package:lifecare_api/core/errors/api_error.dart';

/// Pure, DB-free helpers behind the /v1/reports/* endpoints — kept separate
/// from ReportsRepository so they're unit-testable (see
/// test/modules/reports/report_logic_test.dart).

/// Half-open UTC range [fromUtc, toUtc) covering whole clinic calendar days.
class ClinicDateRange {
  final DateTime fromUtc;
  final DateTime toUtc;
  const ClinicDateRange(this.fromUtc, this.toUtc);
}

final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime _parseDate(String? raw, String field) {
  final parsed = raw != null && _datePattern.hasMatch(raw)
      ? DateTime.tryParse('${raw}T00:00:00Z')
      : null;
  // DateTime.tryParse rolls 2026-13-01 over into 2027-01-01; round-tripping
  // the string catches that instead of silently shifting the report period.
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != raw) {
    throw ApiError.validationError(
      '$field must be a date in YYYY-MM-DD format',
      details: [{'field': field, 'message': 'Expected YYYY-MM-DD'}],
    );
  }
  return parsed;
}

/// Parses inclusive clinic-local `from`/`to` dates (YYYY-MM-DD) into UTC
/// query bounds: `created_at >= fromUtc AND created_at < toUtc`.
ClinicDateRange parseClinicDateRange(
  String? from,
  String? to, {
  required Duration offset,
  int maxDays = 366,
}) {
  final start = _parseDate(from, 'from');
  final end = _parseDate(to, 'to');
  if (end.isBefore(start)) {
    throw ApiError.validationError('"to" must be on or after "from"');
  }
  if (end.difference(start).inDays > maxDays) {
    throw ApiError.validationError('Choose a range of one year or less');
  }
  return ClinicDateRange(
    start.subtract(offset),
    end.add(const Duration(days: 1)).subtract(offset),
  );
}

int? parseOptionalNonNegativeInt(String? raw, String field) {
  if (raw == null || raw.isEmpty) return null;
  final value = int.tryParse(raw);
  if (value == null || value < 0) {
    throw ApiError.validationError(
      '$field must be a whole number of 0 or more',
      details: [{'field': field, 'message': 'Expected a non-negative integer'}],
    );
  }
  return value;
}

/// One wallet_ledger row, reduced to what the running balance needs.
class LedgerMovement {
  final String type;
  final int amount;
  final DateTime at;
  const LedgerMovement({required this.type, required this.amount, required this.at});
}

class DebtSummary {
  /// When the balance last went from >= 0 to below zero and stayed there.
  final DateTime? owingSince;
  final DateTime? lastPaymentAt;
  const DebtSummary({this.owingSince, this.lastPaymentAt});
}

// Same sign convention as AccountStatementService._creditTypes: amounts are
// stored as positive magnitudes except 'adjustment', which is pre-signed.
const _creditTypes = {'deposit', 'refund', 'adjustment', 'opening_balance', 'reversal'};

/// [movements] must be in chronological order.
DebtSummary debtSummary(List<LedgerMovement> movements) {
  var balance = 0;
  DateTime? owingSince;
  DateTime? lastPaymentAt;
  for (final m in movements) {
    final wasNegative = balance < 0;
    balance += _creditTypes.contains(m.type) ? m.amount : -m.amount;
    if (m.type == 'deposit') lastPaymentAt = m.at;
    if (balance >= 0) {
      owingSince = null;
    } else if (!wasNegative) {
      owingSince = m.at;
    }
  }
  return DebtSummary(owingSince: owingSince, lastPaymentAt: lastPaymentAt);
}

DateTime? latestActivity(Iterable<DateTime?> timestamps) {
  DateTime? latest;
  for (final t in timestamps) {
    if (t != null && (latest == null || t.isAfter(latest))) latest = t;
  }
  return latest;
}

/// [now] minus [months] calendar months, clamped to the target month's
/// last day (31 Aug − 6 months → 28 Feb, not 3 Mar).
DateTime inactivityCutoff(DateTime now, int months) {
  final monthIndex = now.year * 12 + (now.month - 1) - months;
  final year = monthIndex ~/ 12;
  final month = monthIndex % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  return DateTime.utc(
    year,
    month,
    now.day > lastDay ? lastDay : now.day,
    now.hour,
    now.minute,
    now.second,
  );
}
