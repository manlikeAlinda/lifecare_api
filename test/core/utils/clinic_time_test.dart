import 'package:test/test.dart';
import 'package:lifecare_api/core/utils/clinic_time.dart';

void main() {
  group('ClinicTime.parseDbUtc', () {
    // DATETIME columns are stored in UTC but come back with no zone marker;
    // DateTime.parse alone would read them as server-local time.
    test('reads a MySQL DATETIME string as UTC, whatever the server zone', () {
      expect(
        ClinicTime.parseDbUtc('2026-09-29 22:15:00.123456'),
        DateTime.utc(2026, 9, 29, 22, 15, 0, 123, 456),
      );
    });

    test('accepts values without fractional seconds', () {
      expect(ClinicTime.parseDbUtc('2026-09-29 22:15:00'),
          DateTime.utc(2026, 9, 29, 22, 15));
    });
  });
}
