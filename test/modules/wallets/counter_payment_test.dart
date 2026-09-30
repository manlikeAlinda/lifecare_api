import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/wallets/wallet_service.dart';

void main() {
  group('parseCounterPayment', () {
    test('accepts a whole-shilling amount and a known method', () {
      final p = parseCounterPayment({
        'amount': 25000,
        'payment_method': 'cash',
        'payment_reference': '  RCPT-001 ',
        'notes': ' paid at desk ',
      });
      expect(p.amount, 25000);
      expect(p.method, 'cash');
      expect(p.reference, 'RCPT-001');
      expect(p.notes, 'paid at desk');
    });

    test('blank reference and notes become null', () {
      final p = parseCounterPayment(
          {'amount': 1000, 'payment_method': 'bank', 'payment_reference': ' ', 'notes': ''});
      expect(p.reference, isNull);
      expect(p.notes, isNull);
    });

    test('every supported method is accepted', () {
      for (final m in counterPaymentMethods) {
        expect(parseCounterPayment({'amount': 1, 'payment_method': m}).method, m);
      }
    });

    test('rejects a missing, zero, negative or fractional amount', () {
      for (final amount in [null, 0, -500, 12.5, '1000']) {
        expect(
          () => parseCounterPayment({'amount': amount, 'payment_method': 'cash'}),
          throwsA(isA<ApiError>()),
          reason: 'amount=$amount',
        );
      }
    });

    test('rejects an unknown or missing payment method', () {
      expect(() => parseCounterPayment({'amount': 100, 'payment_method': 'cheque'}),
          throwsA(isA<ApiError>()));
      expect(() => parseCounterPayment({'amount': 100}), throwsA(isA<ApiError>()));
    });

    test('rejects an over-long reference', () {
      expect(
        () => parseCounterPayment(
            {'amount': 100, 'payment_method': 'card', 'payment_reference': 'x' * 65}),
        throwsA(isA<ApiError>()),
      );
    });
  });
}
