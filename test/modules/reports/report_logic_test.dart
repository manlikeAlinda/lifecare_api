import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/reports/report_logic.dart';

void main() {
  group('parseClinicDateRange', () {
    test('converts inclusive clinic dates to a half-open UTC range', () {
      final r = parseClinicDateRange('2026-09-01', '2026-09-30',
          offset: const Duration(hours: 3));
      expect(r.fromUtc, DateTime.utc(2026, 8, 31, 21));
      expect(r.toUtc, DateTime.utc(2026, 9, 30, 21));
    });

    test('missing or malformed dates are rejected', () {
      expect(() => parseClinicDateRange(null, '2026-09-30', offset: Duration.zero),
          throwsA(isA<ApiError>()));
      expect(() => parseClinicDateRange('2026-13-01', '2026-09-30', offset: Duration.zero),
          throwsA(isA<ApiError>()));
    });

    test('end before start is rejected', () {
      expect(() => parseClinicDateRange('2026-09-30', '2026-09-01', offset: Duration.zero),
          throwsA(isA<ApiError>()));
    });

    test('ranges longer than a year are rejected', () {
      expect(() => parseClinicDateRange('2025-01-01', '2026-09-01', offset: Duration.zero),
          throwsA(isA<ApiError>()));
    });
  });

  group('parseOptionalNonNegativeInt', () {
    test('absent or empty is null', () {
      expect(parseOptionalNonNegativeInt(null, 'x'), isNull);
      expect(parseOptionalNonNegativeInt('', 'x'), isNull);
    });
    test('valid value parses', () {
      expect(parseOptionalNonNegativeInt('5000', 'x'), 5000);
    });
    test('negative or non-numeric is rejected', () {
      expect(() => parseOptionalNonNegativeInt('-1', 'x'), throwsA(isA<ApiError>()));
      expect(() => parseOptionalNonNegativeInt('abc', 'x'), throwsA(isA<ApiError>()));
    });
  });

  group('debtSummary', () {
    LedgerMovement m(String type, int amount, int day) =>
        LedgerMovement(type: type, amount: amount, at: DateTime.utc(2026, 9, day));

    test('owing since the deduction that first took the balance below zero', () {
      final s = debtSummary([
        m('deposit', 1000, 1),
        m('deduction', 800, 2), // 200
        m('deduction', 500, 3), // -300  ← went negative here
        m('deduction', 100, 4), // -400
      ]);
      expect(s.owingSince, DateTime.utc(2026, 9, 3));
      expect(s.lastPaymentAt, DateTime.utc(2026, 9, 1));
    });

    test('a repayment back to zero resets the owing-since date', () {
      final s = debtSummary([
        m('deduction', 500, 1), // -500
        m('deposit', 500, 2), //    0  ← cleared
        m('deduction', 100, 5), // -100 ← new debt
      ]);
      expect(s.owingSince, DateTime.utc(2026, 9, 5));
      expect(s.lastPaymentAt, DateTime.utc(2026, 9, 2));
    });

    test('reversal and signed adjustments move the balance correctly', () {
      final s = debtSummary([
        m('deduction', 500, 1), // -500 ← negative
        m('reversal', 500, 2), //    0 ← cleared
        m('adjustment', -50, 3), // -50 ← negative again
      ]);
      expect(s.owingSince, DateTime.utc(2026, 9, 3));
      expect(s.lastPaymentAt, isNull);
    });
  });

  group('latestActivity', () {
    test('picks the most recent non-null timestamp', () {
      expect(
        latestActivity([null, DateTime.utc(2026, 1, 1), DateTime.utc(2026, 5, 1)]),
        DateTime.utc(2026, 5, 1),
      );
    });
    test('all null is null', () {
      expect(latestActivity([null, null]), isNull);
    });
  });

  group('inactivityCutoff', () {
    test('subtracts calendar months', () {
      expect(inactivityCutoff(DateTime.utc(2026, 9, 29), 6), DateTime.utc(2026, 3, 29));
    });
    test('clamps to the end of a shorter month', () {
      expect(inactivityCutoff(DateTime.utc(2026, 8, 31), 6), DateTime.utc(2026, 2, 28));
    });
  });
}
