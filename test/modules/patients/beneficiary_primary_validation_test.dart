import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/patients/patient_service.dart';

void main() {
  group('validateBeneficiaryHasPrimary', () {
    test('dependent with a primary account passes', () {
      expect(
        () => validateBeneficiaryHasPrimary(
          accountType: 'dependent',
          primaryAccountId: '4bd82047-19ca-45c4-b5bd-14d800898f9e',
        ),
        returnsNormally,
      );
    });

    test('dependent without a primary account is rejected', () {
      expect(
        () => validateBeneficiaryHasPrimary(
          accountType: 'dependent',
          primaryAccountId: null,
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('non-dependent account types never need a primary account', () {
      for (final type in ['individual', 'family', 'corporate', null]) {
        expect(
          () => validateBeneficiaryHasPrimary(
            accountType: type,
            primaryAccountId: null,
          ),
          returnsNormally,
        );
      }
    });
  });
}
