import 'package:dotenv/dotenv.dart';

class AppConfig {
  static late DotEnv _env;

  static void load() {
    _env = DotEnv(includePlatformEnvironment: true)..load();
  }

  static String get dbHost => _env['DB_HOST'] ?? 'localhost';
  static int get dbPort => int.parse(_env['DB_PORT'] ?? '3306');
  static String get dbName => _env['DB_NAME'] ?? 'lifecare';
  static String get dbUser => _env['DB_USER'] ?? 'root';
  static String get dbPassword => _env['DB_PASSWORD'] ?? '';
  static int get dbPoolSize => int.parse(_env['DB_POOL_SIZE'] ?? '2');

  static String get jwtSecret {
    final secret = _env['JWT_SECRET'];
    if (secret == null || secret.length < 32) {
      throw StateError('JWT_SECRET must be set and at least 32 characters long');
    }
    return secret;
  }

  static int get jwtAccessExpiryMinutes =>
      int.parse(_env['JWT_ACCESS_EXPIRY_MINUTES'] ?? '15');

  static int get jwtRefreshExpiryDays =>
      int.parse(_env['JWT_REFRESH_EXPIRY_DAYS'] ?? '30');

  static int get port => int.parse(_env['PORT'] ?? _env['SERVER_PORT'] ?? '8080');

  static String get appEnv => _env['APP_ENV'] ?? 'production';

  static bool get isProduction => appEnv == 'production';

  static String get smtpUser => _env['SMTP_USER'] ?? '';
  static String get smtpPassword => _env['SMTP_PASSWORD'] ?? '';

  // ── Public backend URL (used as webhook callback base) ─────────────────────
  static String get publicUrl =>
      _env['PUBLIC_URL'] ?? 'https://lifecareapi-production.up.railway.app';

  // ── Pesapal payments ───────────────────────────────────────────────────────
  static String get pesapalConsumerKey => _env['PESAPAL_CONSUMER_KEY'] ?? '';
  static String get pesapalConsumerSecret => _env['PESAPAL_CONSUMER_SECRET'] ?? '';
  // Sandbox: https://cybqa.pesapal.com/pesapalv3
  // Production: https://pay.pesapal.com/v3
  static String get pesapalBaseUrl =>
      _env['PESAPAL_BASE_URL'] ?? 'https://cybqa.pesapal.com/pesapalv3';
}
