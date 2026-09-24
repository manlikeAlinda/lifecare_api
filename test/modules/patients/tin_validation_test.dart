import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/patients/patient_service.dart';

void main() {
  group('validateTinSubmission', () {
    test('non-tin id_type is always a no-op, regardless of account type', () {
      expect(
        () => validateTinSubmission(
          idType: 'national_id',
          nationalId: '12345',
          effectiveAccountType: 'individual',
        ),
        returnsNormally,
      );
    });

    test('valid 10-character TIN on a corporate account passes', () {
      expect(
        () => validateTinSubmission(
          idType: 'tin',
          nationalId: '1234567890',
          effectiveAccountType: 'corporate',
        ),
        returnsNormally,
      );
    });

    test('TIN on a non-corporate account is rejected', () {
      expect(
        () => validateTinSubmission(
          idType: 'tin',
          nationalId: '1234567890',
          effectiveAccountType: 'individual',
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('wrong-length TIN is rejected', () {
      expect(
        () => validateTinSubmission(
          idType: 'tin',
          nationalId: '123456789', // 9 chars
          effectiveAccountType: 'corporate',
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('TIN withheld on a corporate account passes (optional)', () {
      expect(
        () => validateTinSubmission(
          idType: 'tin',
          nationalId: null,
          effectiveAccountType: 'corporate',
        ),
        returnsNormally,
      );
    });

    test('leading-zero TIN is accepted — proves no numeric coercion', () {
      expect(
        () => validateTinSubmission(
          idType: 'tin',
          nationalId: '0123456789',
          effectiveAccountType: 'corporate',
        ),
        returnsNormally,
      );
    });
  });
}
