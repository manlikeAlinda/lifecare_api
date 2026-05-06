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

  // ── MTN Mobile Money Collection ────────────────────────────────────────────
  static String get mtnSubscriptionKey => _env['MTN_SUBSCRIPTION_KEY'] ?? '';
  static String get mtnApiUser => _env['MTN_API_USER'] ?? '';
  static String get mtnApiKey => _env['MTN_API_KEY'] ?? '';
  static String get mtnTargetEnv => _env['MTN_TARGET_ENV'] ?? 'sandbox';
  static String get mtnBaseUrl =>
      _env['MTN_BASE_URL'] ?? 'https://ericssonbasicapi2.azure-api.net';

  // ── Flutterwave (card payments) ────────────────────────────────────────────
  // Get keys at: https://dashboard.flutterwave.com → Settings → API
  static String get flutterwaveSecretKey => _env['FLUTTERWAVE_SECRET_KEY'] ?? '';
  // Set a random string in your Flutterwave dashboard → Webhooks → Secret hash
  static String get flutterwaveSecretHash => _env['FLUTTERWAVE_SECRET_HASH'] ?? '';
}
