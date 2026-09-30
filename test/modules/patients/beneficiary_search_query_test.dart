import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/patients/patient_service.dart';

void main() {
  group('parseBeneficiarySearch', () {
    test('trims the query and defaults the limit to 10', () {
      final p = parseBeneficiarySearch('  jo ', null);
      expect(p.query, 'jo');
      expect(p.limit, 10);
    });

    test('rejects queries shorter than 2 characters', () {
      expect(() => parseBeneficiarySearch('j', null), throwsA(isA<ApiError>()));
      expect(() => parseBeneficiarySearch(' ', null), throwsA(isA<ApiError>()));
      expect(() => parseBeneficiarySearch(null, null), throwsA(isA<ApiError>()));
    });

    test('caps the limit at 20 and floors it at 1', () {
      expect(parseBeneficiarySearch('jo', '500').limit, 20);
      expect(parseBeneficiarySearch('jo', '0').limit, 1);
      expect(parseBeneficiarySearch('jo', '15').limit, 15);
    });

    test('rejects a non-numeric limit', () {
      expect(() => parseBeneficiarySearch('jo', 'lots'), throwsA(isA<ApiError>()));
    });

    test('escapes LIKE wildcards so they match literally', () {
      expect(parseBeneficiarySearch('50%_off', null).likePattern, r'%50\%\_off%');
    });
  });
}
