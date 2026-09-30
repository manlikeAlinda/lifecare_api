import 'package:test/test.dart';
import 'package:lifecare_api/core/services/pesapal_service.dart';

void main() {
  test('Pesapal payment methods map to the report codes', () {
    expect(mapPesapalPaymentMethod('Visa'), 'card');
    expect(mapPesapalPaymentMethod('MasterCard'), 'card');
    expect(mapPesapalPaymentMethod('American Express'), 'card');
    expect(mapPesapalPaymentMethod('MTNUG'), 'mobile_money');
    expect(mapPesapalPaymentMethod('Airtel Money'), 'mobile_money');
    expect(mapPesapalPaymentMethod('MpesaKE'), 'mobile_money');
    expect(mapPesapalPaymentMethod('Bank Transfer'), 'bank');
    expect(mapPesapalPaymentMethod('EquityBank'), 'bank');
  });

  test('unknown or missing methods stay unrecorded rather than guessed', () {
    expect(mapPesapalPaymentMethod(null), isNull);
    expect(mapPesapalPaymentMethod(''), isNull);
    expect(mapPesapalPaymentMethod('SomethingNew'), isNull);
  });
}
