import 'package:test/test.dart';
import 'package:lifecare_api/core/config/app_config.dart';

void main() {
  group('AppConfig fail-fast getters', () {
    test('dbUser throws when unset', () {
      AppConfig.loadFromMap({});
      expect(() => AppConfig.dbUser, throwsStateError);
    });

    test('dbPassword throws when unset', () {
      AppConfig.loadFromMap({});
      expect(() => AppConfig.dbPassword, throwsStateError);
    });

    test('pesapalConsumerKey throws when unset', () {
      AppConfig.loadFromMap({});
      expect(() => AppConfig.pesapalConsumerKey, throwsStateError);
    });

    test('pesapalConsumerSecret throws when unset', () {
      AppConfig.loadFromMap({});
      expect(() => AppConfig.pesapalConsumerSecret, throwsStateError);
    });

    test('dbUser/dbPassword return the configured value when set', () {
      AppConfig.loadFromMap({'DB_USER': 'app', 'DB_PASSWORD': 'secret'});
      expect(AppConfig.dbUser, 'app');
      expect(AppConfig.dbPassword, 'secret');
    });
  });

  group('AppConfig.pesapalBaseUrl', () {
    test('production boot with no override throws instead of defaulting to sandbox', () {
      AppConfig.loadFromMap({'APP_ENV': 'production'});
      expect(() => AppConfig.pesapalBaseUrl, throwsStateError);
    });

    test('production boot never resolves to the sandbox URL', () {
      AppConfig.loadFromMap({
        'APP_ENV': 'production',
        'PESAPAL_BASE_URL': 'https://pay.pesapal.com/v3',
      });
      expect(AppConfig.pesapalBaseUrl, isNot(contains('cybqa')));
      expect(AppConfig.pesapalBaseUrl, 'https://pay.pesapal.com/v3');
    });

    test('non-production falls back to the sandbox URL when unset', () {
      AppConfig.loadFromMap({'APP_ENV': 'development'});
      expect(AppConfig.pesapalBaseUrl, contains('cybqa'));
    });

    test('APP_ENV unset defaults to production (fail-closed)', () {
      AppConfig.loadFromMap({});
      expect(AppConfig.isProduction, isTrue);
      expect(() => AppConfig.pesapalBaseUrl, throwsStateError);
    });
  });
}
