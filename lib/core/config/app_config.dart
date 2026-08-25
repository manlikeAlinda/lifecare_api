import 'package:dotenv/dotenv.dart';
import 'package:meta/meta.dart';

class AppConfig {
  static late DotEnv _env;

  static void load() {
    _env = DotEnv(includePlatformEnvironment: true)..load();
  }

  /// Test-only: seed config from a map instead of the real environment/.env
  /// file, so getters (including the fail-fast ones) can be exercised
  /// without touching process state.
  @visibleForTesting
  static void loadFromMap(Map<String, String> values) {
    _env = DotEnv()..addAll(values);
  }

  static String _required(String key) {
    final value = _env[key];
    if (value == null || value.isEmpty) {
      throw StateError('$key must be set');
    }
    return value;
  }

  /// Touches every security-relevant getter so a missing var fails the boot
  /// immediately with a clear message, instead of surfacing later the first
  /// time that credential happens to be used (e.g. on the first deposit).
  static void validateSecurityConfig() {
    jwtSecret;
    dbUser;
    dbPassword;
    pesapalConsumerKey;
    pesapalConsumerSecret;
    pesapalBaseUrl;
  }

  static String get dbHost => _env['DB_HOST'] ?? 'localhost';
  static int get dbPort => int.parse(_env['DB_PORT'] ?? '3306');
  static String get dbName => _env['DB_NAME'] ?? 'lifecare';
  static String get dbUser => _required('DB_USER');
  static String get dbPassword => _required('DB_PASSWORD');
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
  static String get pesapalConsumerKey => _required('PESAPAL_CONSUMER_KEY');
  static String get pesapalConsumerSecret => _required('PESAPAL_CONSUMER_SECRET');

  // Sandbox: https://cybqa.pesapal.com/pesapalv3
  // Production: https://pay.pesapal.com/v3
  //
  // In production, PESAPAL_BASE_URL must be set explicitly — there is no
  // default, so a misconfigured prod deploy fails to boot instead of
  // silently taking payments against the sandbox gateway.
  static String get pesapalBaseUrl {
    if (isProduction) return _required('PESAPAL_BASE_URL');
    return _env['PESAPAL_BASE_URL'] ?? 'https://cybqa.pesapal.com/pesapalv3';
  }

  // ── TOTP 2FA (patient login) ─────────────────────────────────────────────
  // Optional by design — 2FA can be off. Callers must check `totpConfigured`
  // and degrade gracefully (reject setup with a clear error) rather than
  // crash, matching the boot-must-not-fail contract for optional features.
  static String get totpEncryptionKeyRaw => _env['TOTP_ENCRYPTION_KEY'] ?? '';
  static bool get totpConfigured => totpEncryptionKeyRaw.length >= 32;

  // ── PII field-level encryption (patients.phone_e164 / national_id) ────────
  static String get piiEncryptionKeyRaw => _env['PII_ENCRYPTION_KEY'] ?? '';
  static bool get piiConfigured => piiEncryptionKeyRaw.length >= 32;

  // ── KYC (Smile Identity) ────────────────────────────────────────────────────
  // Unset ⇒ KYC submissions are accepted and queued for manual review only;
  // no automated verification call is made. See kyc_service.dart.
  static String get smilePartnerId => _env['SMILE_PARTNER_ID'] ?? '';
  static String get smileApiKey => _env['SMILE_API_KEY'] ?? '';
  static bool get smileConfigured =>
      smilePartnerId.isNotEmpty && smileApiKey.isNotEmpty;
  static String get smileBaseUrl =>
      _env['SMILE_BASE_URL'] ??
      (isProduction
          ? 'https://api.smileidentity.com/v1'
          : 'https://testapi.smileidentity.com/v1');

  // ── System actor (audit_log actor for webhook/provider-originated writes) ──
  // Fixed UUID, must match the seeded row in migrations/026_system_actor.sql.
  static const String systemActorId = '2f6554b5-a339-42cb-9011-de5e893aa112';

  // ── Clinic operating timezone ─────────────────────────────────────────────
  // Fixed UTC offset rather than an IANA zone name — this clinic is
  // single-site (Uganda, EAT, UTC+3, no DST), so a plain offset avoids
  // pulling in a timezone-database dependency for a distinction that
  // doesn't apply here. "Today"/"this month" boundaries for dashboard KPIs
  // are computed against this offset, not the server's own clock, so they
  // match the clinic's actual business day regardless of which region the
  // API happens to be hosted in.
  static int get clinicTzOffsetMinutes =>
      int.parse(_env['CLINIC_TZ_OFFSET_MINUTES'] ?? '180');
}
