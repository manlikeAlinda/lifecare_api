import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/encounters/encounter_service.dart';

void main() {
  const companyId = '11111111-1111-1111-1111-111111111111';
  const otherCompanyId = '22222222-2222-2222-2222-222222222222';
  const beneficiaryId = '33333333-3333-3333-3333-333333333333';

  final corporate = {'id': companyId, 'account_type': 'corporate'};
  final family = {'id': companyId, 'account_type': 'family'};
  Map<String, dynamic> beneficiary({
    String primary = companyId,
    bool active = true,
  }) =>
      {
        'id': beneficiaryId,
        'account_type': 'dependent',
        'primary_account_id': primary,
        'is_active': active,
      };

  group('validateVisitBeneficiary', () {
    test('accepts an active beneficiary of the same account', () {
      expect(
        () => validateVisitBeneficiary(
          account: corporate,
          dependentId: beneficiaryId,
          beneficiary: beneficiary(),
        ),
        returnsNormally,
      );
    });

    test("rejects another company's beneficiary", () {
      expect(
        () => validateVisitBeneficiary(
          account: corporate,
          dependentId: beneficiaryId,
          beneficiary: beneficiary(primary: otherCompanyId),
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('rejects an unknown or deleted beneficiary', () {
      expect(
        () => validateVisitBeneficiary(
          account: corporate,
          dependentId: beneficiaryId,
          beneficiary: null,
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('rejects an inactive beneficiary', () {
      expect(
        () => validateVisitBeneficiary(
          account: corporate,
          dependentId: beneficiaryId,
          beneficiary: beneficiary(active: false),
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('a corporate visit must name a beneficiary', () {
      expect(
        () => validateVisitBeneficiary(
          account: corporate,
          dependentId: null,
          beneficiary: null,
        ),
        throwsA(isA<ApiError>()),
      );
    });

    test('a family account holder may visit without a beneficiary', () {
      expect(
        () => validateVisitBeneficiary(
          account: family,
          dependentId: null,
          beneficiary: null,
        ),
        returnsNormally,
      );
    });
  });
}
