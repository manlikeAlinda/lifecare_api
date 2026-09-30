import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_service.dart';

void main() {
  group('ensureCanGenerateCredentials', () {
    test('first-time generation is allowed', () {
      expect(() => ensureCanGenerateCredentials(exists: false, replaceExisting: false),
          returnsNormally);
    });

    test('a repeat without replace_existing is refused (409), keeping the PIN', () {
      expect(
        () => ensureCanGenerateCredentials(exists: true, replaceExisting: false),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });

    test('an explicit regenerate replaces existing credentials', () {
      expect(() => ensureCanGenerateCredentials(exists: true, replaceExisting: true),
          returnsNormally);
    });
  });
}
