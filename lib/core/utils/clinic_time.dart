import 'package:lifecare_api/core/config/app_config.dart';

/// Single source of truth for "today"/"this month" boundaries used by every
/// dashboard KPI query. Computed against the clinic's configured operating
/// timezone (AppConfig.clinicTzOffsetMinutes), not the API server's own
/// clock — the server may run in a different region/timezone than the
/// clinic, and using its local time would silently shift day/month
/// boundaries by however many hours the two disagree by.
///
/// Assumes timestamp columns (created_at, visited_at, etc.) are stored in
/// UTC, which is the standard behavior for a MySQL/MariaDB server whose
/// session `time_zone` is UTC (the common default for managed/cloud
/// hosting). If that's ever not the case, the boundaries below would need
/// an additional DB-side offset — verify with
/// `SELECT @@session.time_zone, NOW(), UTC_TIMESTAMP();` if day boundaries
/// ever look off by a fixed number of hours.
class ClinicTime {
  const ClinicTime._();

  static Duration get _offset =>
      Duration(minutes: AppConfig.clinicTzOffsetMinutes);

  /// The current instant, expressed in clinic wall-clock terms. Still a
  /// UTC-flagged DateTime — only the Y/M/D/H/M/S fields are shifted — so it
  /// must never be used directly as a query bound; use it only to derive
  /// calendar boundaries via [startOfToday]/[startOfMonth] below.
  static DateTime _nowClinic() => DateTime.now().toUtc().add(_offset);

  /// Start of the current clinic calendar day, as a real UTC instant
  /// suitable for a `created_at >= :from` query bound.
  static DateTime startOfToday() {
    final c = _nowClinic();
    return DateTime.utc(c.year, c.month, c.day).subtract(_offset);
  }

  static DateTime endOfToday() => startOfToday().add(const Duration(days: 1));

  /// Start of the current clinic calendar month.
  static DateTime startOfMonth() {
    final c = _nowClinic();
    return DateTime.utc(c.year, c.month, 1).subtract(_offset);
  }

  /// Start of a rolling trailing window ending now (inclusive).
  static DateTime startOfLastNDays(int n) =>
      DateTime.now().toUtc().subtract(Duration(days: n));

  static DateTime nowUtc() => DateTime.now().toUtc();

  /// The clinic-local calendar date (Y/M/D only, UTC-flagged for easy
  /// comparison/subtraction) that a given UTC instant falls on. Use this to
  /// bucket rows by "which clinic day" in application code rather than
  /// relying on the DB server's own session timezone.
  static DateTime clinicDateOf(DateTime utcInstant) {
    final clinic = utcInstant.toUtc().add(_offset);
    return DateTime.utc(clinic.year, clinic.month, clinic.day);
  }

  /// MySQL DATETIME literal, e.g. '2026-08-13 21:00:00'.
  static String sql(DateTime utc) =>
      utc.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

  /// The clinic's UTC offset as a display string, e.g. '+03:00' — included
  /// in API responses so the period a figure covers is traceable, not just
  /// asserted by a UI label.
  static String get offsetLabel {
    final m = AppConfig.clinicTzOffsetMinutes;
    final sign = m >= 0 ? '+' : '-';
    final abs = m.abs();
    final h = (abs ~/ 60).toString().padLeft(2, '0');
    final min = (abs % 60).toString().padLeft(2, '0');
    return '$sign$h:$min';
  }
}
