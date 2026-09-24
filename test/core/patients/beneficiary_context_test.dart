import 'package:lifecare_api/core/patients/beneficiary_context.dart';
import 'package:test/test.dart';

void main() {
  group('isBeneficiaryRow', () {
    test('a linked beneficiary is a beneficiary', () {
      expect(
        isBeneficiaryRow({'primary_account_id': 'p-1', 'account_type': 'dependent'}),
        isTrue,
      );
    });

    test('a removed beneficiary (link cleared) is still a beneficiary', () {
      expect(
        isBeneficiaryRow({'primary_account_id': null, 'account_type': 'dependent'}),
        isTrue,
      );
    });

    test('primary accounts are not beneficiaries', () {
      for (final type in ['individual', 'family', 'corporate']) {
        expect(
          isBeneficiaryRow({'primary_account_id': null, 'account_type': type}),
          isFalse,
          reason: type,
        );
      }
    });

    test('a missing row is not a beneficiary', () {
      expect(isBeneficiaryRow(null), isFalse);
    });
  });
}
