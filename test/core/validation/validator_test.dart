import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/validation/validator.dart';

void main() {
  group('Validator.positiveInteger', () {
    test('rejects a non-numeric string amount', () {
      final v = Validator({'amount': 'abc'})..positiveInteger('amount');
      expect(v.isValid, isFalse);
    });

    test('accepts a positive integer', () {
      final v = Validator({'amount': 50000})..positiveInteger('amount');
      expect(v.isValid, isTrue);
    });

    test('rejects zero and negative values', () {
      expect((Validator({'amount': 0})..positiveInteger('amount')).isValid, isFalse);
      expect((Validator({'amount': -5})..positiveInteger('amount')).isValid, isFalse);
    });
  });

  group('Validator.isListOfObjects', () {
    test('rejects a list containing non-object entries', () {
      final v = Validator({'services': ['not-an-object']})
        ..isListOfObjects('services');
      expect(v.isValid, isFalse);
    });

    test('accepts a list of maps', () {
      final v = Validator({'services': [
        {'domain': 'dental', 'service_id': 1}
      ]})
        ..isListOfObjects('services');
      expect(v.isValid, isTrue);
    });
  });

  group('Validator.isListOfStrings', () {
    test('rejects a list containing non-string entries', () {
      final v = Validator({'ids': [1, 2, 3]})..isListOfStrings('ids');
      expect(v.isValid, isFalse);
    });

    test('accepts a list of strings', () {
      final v = Validator({'ids': ['a', 'b']})..isListOfStrings('ids');
      expect(v.isValid, isTrue);
    });
  });

  group('Validator.isBool', () {
    test('rejects a string in place of a boolean', () {
      final v = Validator({'is_active': 'true'})..isBool('is_active');
      expect(v.isValid, isFalse);
    });

    test('accepts an actual boolean', () {
      final v = Validator({'is_active': true})..isBool('is_active');
      expect(v.isValid, isTrue);
    });
  });

  group('Validator.throwIfInvalid', () {
    test('throws a 400 ApiError with field details', () {
      final v = Validator({'amount': 'abc'})..positiveInteger('amount');
      expect(
        v.throwIfInvalid,
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });
}
