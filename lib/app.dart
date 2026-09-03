import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:lifecare_api/core/database/database.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:lifecare_api/core/patients/beneficiary_context.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/middleware/rate_limit_middleware.dart';
import 'package:lifecare_api/core/middleware/request_id_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';

import 'package:lifecare_api/modules/auth/auth_handler.dart';
import 'package:lifecare_api/modules/auth/auth_repository.dart';
import 'package:lifecare_api/modules/auth/auth_service.dart';
import 'package:lifecare_api/modules/users/user_handler.dart';
import 'package:lifecare_api/modules/users/user_repository.dart';
import 'package:lifecare_api/modules/users/user_service.dart';
import 'package:lifecare_api/modules/patients/patient_handler.dart';
import 'package:lifecare_api/modules/patients/patient_repository.dart';
import 'package:lifecare_api/modules/patients/patient_service.dart';
import 'package:lifecare_api/modules/wallets/wallet_handler.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'package:lifecare_api/modules/wallets/wallet_service.dart';
import 'package:lifecare_api/modules/encounters/encounter_handler.dart';
import 'package:lifecare_api/modules/encounters/encounter_repository.dart';
import 'package:lifecare_api/modules/encounters/encounter_service.dart';
import 'package:lifecare_api/modules/catalog/catalog_handler.dart';
import 'package:lifecare_api/modules/catalog/catalog_repository.dart';
import 'package:lifecare_api/modules/catalog/catalog_service.dart';
import 'package:lifecare_api/modules/analytics/analytics_handler.dart';
import 'package:lifecare_api/modules/analytics/analytics_repository.dart';
import 'package:lifecare_api/modules/analytics/analytics_service.dart';
import 'package:lifecare_api/modules/patient_auth/patient_auth_handler.dart';
import 'package:lifecare_api/modules/patient_auth/patient_auth_repository.dart';
import 'package:lifecare_api/modules/patient_auth/patient_auth_service.dart';
import 'package:lifecare_api/modules/patient_totp/patient_totp_handler.dart';
import 'package:lifecare_api/modules/patient_totp/patient_totp_service.dart';
import 'package:lifecare_api/modules/kyc/kyc_handler.dart';
import 'package:lifecare_api/modules/kyc/kyc_repository.dart';
import 'package:lifecare_api/modules/kyc/kyc_service.dart';
import 'package:lifecare_api/core/services/smile_identity_service.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_handler.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_repository.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_service.dart';
import 'package:lifecare_api/core/services/email_service.dart';
import 'package:lifecare_api/core/services/pesapal_service.dart';
import 'package:lifecare_api/modules/deposits/deposit_handler.dart';
import 'package:lifecare_api/modules/deposits/deposit_repository.dart';
import 'package:lifecare_api/modules/deposits/deposit_service.dart';
import 'package:lifecare_api/modules/checkout/checkout_handler.dart';
import 'package:lifecare_api/modules/checkout/checkout_repository.dart';
import 'package:lifecare_api/modules/checkout/checkout_service.dart';
import 'package:lifecare_api/core/services/pii_encryption_service.dart';
import 'package:lifecare_api/modules/ads/ad_handler.dart';
import 'package:lifecare_api/modules/ads/ad_repository.dart';
import 'package:lifecare_api/modules/ads/ad_service.dart';
import 'package:lifecare_api/modules/audit/audit_handler.dart';
import 'package:lifecare_api/modules/audit/audit_repository.dart';
import 'package:lifecare_api/modules/audit/audit_service.dart';

Handler buildApp() {
  final pool = Database.pool;

  // ── Repositories ────────────────────────────────────────────────────────────
  final authRepo = AuthRepository(pool);
  final userRepo = UserRepository(pool);
  final piiEncryptionService = PiiEncryptionService();
  final walletRepo = WalletRepository(pool);
  final patientRepo = PatientRepository(pool, piiEncryptionService, walletRepo);
  final encounterRepo = EncounterRepository(pool);
  final catalogRepo = CatalogRepository(pool);
  final analyticsRepo = AnalyticsRepository(pool);
  final patientAuthRepo = PatientAuthRepository(pool);
  final patientCredRepo = PatientCredentialsRepository(pool);
  final depositRepo = DepositRepository(pool);
  final kycRepo = KycRepository(pool);
  final checkoutRepo = CheckoutRepository(pool);
  final adRepo = AdRepository(pool);
  final auditRepo = AuditRepository(pool);

  // ── Services ────────────────────────────────────────────────────────────────
  final authService = AuthService(authRepo);
  final userService = UserService(userRepo);
  final patientService = PatientService(patientRepo);
  final walletService = WalletService(walletRepo);
  final encounterService = EncounterService(encounterRepo, walletRepo, catalogRepo);
  final catalogService = CatalogService(catalogRepo);
  final analyticsService = AnalyticsService(analyticsRepo);
  final emailService = EmailService();
  final patientTotpService = PatientTotpService(patientAuthRepo);
  final patientAuthService =
      PatientAuthService(patientAuthRepo, authService, patientTotpService);
  final patientCredService =
      PatientCredentialsService(patientCredRepo, patientRepo, emailService);
  final pesapalService = PesapalService();
  final depositService = DepositService(depositRepo, walletRepo, patientRepo, pesapalService);
  final smileIdentityService = SmileIdentityService();
  final kycService = KycService(kycRepo, smileIdentityService);
  final checkoutService = CheckoutService(checkoutRepo, walletRepo);
  final adService = AdService(adRepo);
  final auditService = AuditService(auditRepo);

  // ── Handlers ─────────────────────────────────────────────────────────────────
  final authHandler = AuthHandler(authService);
  final userHandler = UserHandler(userService);
  final patientHandler = PatientHandler(patientService);
  final walletHandler = WalletHandler(walletService);
  final encounterHandler = EncounterHandler(encounterService);
  final catalogHandler = CatalogHandler(catalogService);
  final analyticsHandler = AnalyticsHandler(analyticsService);
  final patientAuthHandler = PatientAuthHandler(patientAuthService);
  final patientTotpHandler = PatientTotpHandler(patientTotpService);
  final patientCredHandler = PatientCredentialsHandler(patientCredService);
  final depositHandler = DepositHandler(depositService);
  final kycHandler = KycHandler(kycService);
  final checkoutHandler = CheckoutHandler(checkoutService);
  final adHandler = AdHandler(adService);
  final auditHandler = AuditHandler(auditService);

  // ── Middleware pipelines ─────────────────────────────────────────────────────
  final auth = authMiddleware();
  final adminOnly = Pipeline().addMiddleware(auth).addMiddleware(requireAdmin());
  final patientAuth2 = patientAuthMiddleware();

  // ── Router ───────────────────────────────────────────────────────────────────
  final router = Router();

  // Health check (public)
  router.get('/health', (Request _) => Response.ok('{"status":"ok"}',
      headers: {'content-type': 'application/json'}));

  // ── Auth (IAM) ───────────────────────────────────────────────────────────────
  router.post(
    '/v1/auth/login',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(authHandler.login),
  );
  router.post(
    '/v1/auth/refresh',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(refreshLimiter))
        .addHandler(authHandler.refresh),
  );
  router.post(
    '/v1/auth/logout',
    Pipeline().addMiddleware(auth).addHandler(authHandler.logout),
  );

  // ── Users (admin only for list/create/delete/role; auth for own record/password) ─
  router.get(
    '/v1/users',
    adminOnly.addHandler(userHandler.list),
  );
  router.post(
    '/v1/users',
    adminOnly.addHandler(userHandler.create),
  );
  router.get(
    '/v1/users/me',
    Pipeline().addMiddleware(auth).addHandler(userHandler.me),
  );
  // /roles must be before /<id> to prevent the wildcard from catching it
  router.get(
    '/v1/users/roles',
    Pipeline().addMiddleware(auth).addHandler(userHandler.roles),
  );
  router.get(
    '/v1/users/<id>',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.getById(req, req.params['id']!),
        ),
  );
  router.patch(
    '/v1/users/<id>',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.update(req, req.params['id']!),
        ),
  );
  router.delete(
    '/v1/users/<id>',
    adminOnly.addHandler(
      (Request req) => userHandler.delete(req, req.params['id']!),
    ),
  );
  router.get(
    '/v1/users/<id>/preferences',
    Pipeline().addMiddleware(auth).addHandler(
      (Request req) => userHandler.getPreferences(req, req.params['id']!),
    ),
  );
  router.put(
    '/v1/users/<id>/preferences',
    Pipeline().addMiddleware(auth).addHandler(
      (Request req) => userHandler.updatePreferences(req, req.params['id']!),
    ),
  );
  router.get(
    '/v1/users/<id>/audit',
    Pipeline().addMiddleware(auth).addHandler(
      (Request req) => userHandler.auditLog(req, req.params['id']!),
    ),
  );
  router.post(
    '/v1/users/<id>/sessions/revoke',
    Pipeline().addMiddleware(auth).addHandler(
      (Request req) => userHandler.revokeSessions(req, req.params['id']!),
    ),
  );
  router.put(
    '/v1/users/<id>/password',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.changePassword(req, req.params['id']!),
        ),
  );
  router.post(
    '/v1/users/<id>/password',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.changePassword(req, req.params['id']!),
        ),
  );
  router.put(
    '/v1/users/<id>/avatar',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.updateAvatar(req, req.params['id']!),
        ),
  );
  router.get(
    '/v1/users/<id>/avatar',
    Pipeline().addMiddleware(auth).addHandler(
          (Request req) => userHandler.getAvatar(req, req.params['id']!),
        ),
  );
  router.patch(
    '/v1/users/<id>/role',
    adminOnly.addHandler(
      (Request req) => userHandler.changeRole(req, req.params['id']!),
    ),
  );

  // ── Patients ─────────────────────────────────────────────────────────────────
  final patientAuth = Pipeline().addMiddleware(auth);

  router.get('/v1/patients', patientAuth.addHandler(patientHandler.list));
  router.post('/v1/patients', patientAuth.addHandler(patientHandler.create));
  router.patch(
    '/v1/patients',
    patientAuth.addHandler(patientHandler.bulkUpdate),
  );
  router.post(
    '/v1/patients/bulk-status',
    patientAuth.addHandler(patientHandler.bulkUpdateStatus),
  );
  router.post(
    '/v1/patients/bulk-delete',
    adminOnly.addHandler(patientHandler.bulkDelete),
  );
  router.get(
    '/v1/patients/<id>',
    patientAuth.addHandler(
      (Request req) => patientHandler.getById(req, req.params['id']!),
    ),
  );
  router.patch(
    '/v1/patients/<id>',
    patientAuth.addHandler(
      (Request req) => patientHandler.update(req, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/patients/<id>',
    adminOnly.addHandler(
      (Request req) => patientHandler.delete(req, req.params['id']!),
    ),
  );

  // Patient sub-resources
  router.get(
    '/v1/patients/<id>/wallet',
    patientAuth.addHandler(
      (Request req) async {
        final wallet = await walletService.getWalletByPatient(req.params['id']!);
        return okResponse(wallet);
      },
    ),
  );
  router.get(
    '/v1/patients/<id>/encounters',
    patientAuth.addHandler(
      (Request req) async {
        final id = req.params['id']!;
        final limit = parseLimit(req);
        final offset = parseOffset(req);
        // The desktop client calls this same route for two different
        // things: GET /v1/patients/<primaryId>/encounters for a primary's
        // full family history (id = patient_id, matches every encounter
        // billed to them including their beneficiaries'), and
        // GET /v1/patients/<beneficiaryId>/encounters?dependent=true for
        // one beneficiary's own report (id = dependent_id — a beneficiary's
        // encounters always carry the PRIMARY's patient_id for billing, so
        // filtering by patientId: id here would silently return nothing).
        final isDependentReport = queryParam(req, 'dependent') == 'true';
        // Staff/admin (this route's `auth` pipeline) intentionally see the
        // unredacted reason regardless of reason_hidden — the spec's
        // redaction requirement is about protecting a beneficiary from the
        // PRIMARY specifically, and staff already have full clinical/
        // billing visibility elsewhere. Only /v1/patient/visits and
        // /v1/patient/beneficiaries/<id>/visits (patientAuth2, the
        // primary's own session) pass asPrimaryView: true.
        final (encounters, total) = await encounterService.listEncounters(
          patientId: isDependentReport ? null : id,
          dependentId: isDependentReport ? id : null,
          limit: limit,
          offset: offset,
        );
        return okListResponse(encounters, total: total, limit: limit, offset: offset);
      },
    ),
  );

  // Dependents
  router.get(
    '/v1/patients/<id>/dependents',
    patientAuth.addHandler(
      (Request req) => patientHandler.listDependents(req, req.params['id']!),
    ),
  );
  router.post(
    '/v1/patients/<id>/dependents',
    patientAuth.addHandler(
      (Request req) => patientHandler.createDependent(req, req.params['id']!),
    ),
  );
  router.patch(
    '/v1/patients/<patientId>/dependents/<depId>',
    patientAuth.addHandler(
      (Request req) =>
          patientHandler.updateDependent(req, req.params['patientId']!, req.params['depId']!),
    ),
  );
  router.delete(
    '/v1/patients/<patientId>/dependents/<depId>',
    adminOnly.addHandler(
      (Request req) =>
          patientHandler.deleteDependent(req, req.params['patientId']!, req.params['depId']!),
    ),
  );

  // ── Wallets ───────────────────────────────────────────────────────────────────
  router.get('/v1/wallets', patientAuth.addHandler(walletHandler.list));
  // /ledger must be before /<id> to prevent the wildcard from catching it
  router.get(
    '/v1/wallets/ledger',
    patientAuth.addHandler(walletHandler.getGlobalLedger),
  );
  router.get(
    '/v1/wallets/<id>',
    patientAuth.addHandler(
      (Request req) => walletHandler.getById(req, req.params['id']!),
    ),
  );
  router.get(
    '/v1/wallets/<id>/ledger',
    patientAuth.addHandler(
      (Request req) => walletHandler.getLedger(req, req.params['id']!),
    ),
  );
  router.get(
    '/v1/wallets/<id>/dependents',
    patientAuth.addHandler(
      (Request req) => walletHandler.getDependents(req, req.params['id']!),
    ),
  );
  router.post(
    '/v1/wallets/<id>/transactions',
    adminOnly.addHandler(
      (Request req) => walletHandler.createTransaction(req, req.params['id']!),
    ),
  );

  // ── Encounters ────────────────────────────────────────────────────────────────
  router.get('/v1/encounters', patientAuth.addHandler(encounterHandler.list));
  router.post('/v1/encounters', patientAuth.addHandler(encounterHandler.create));
  // static sub-paths must be before /<id> wildcard
  router.get(
    '/v1/encounters/daily-counts',
    patientAuth.addHandler(analyticsHandler.getDailyCounts),
  );
  router.get(
    '/v1/encounters/<id>',
    patientAuth.addHandler(
      (Request req) => encounterHandler.getById(req, req.params['id']!),
    ),
  );
  router.put(
    '/v1/encounters/<id>',
    patientAuth.addHandler(
      (Request req) => encounterHandler.update(req, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/encounters/<id>',
    adminOnly.addHandler(
      (Request req) => encounterHandler.delete(req, req.params['id']!),
    ),
  );
  router.patch(
    '/v1/encounters/<id>/status',
    patientAuth.addHandler(
      (Request req) => encounterHandler.updateStatus(req, req.params['id']!),
    ),
  );

  // ── Catalog ───────────────────────────────────────────────────────────────────
  router.get(
    '/v1/catalog/services',
    patientAuth.addHandler(catalogHandler.listServices),
  );
  router.get(
    '/v1/catalog/drugs',
    patientAuth.addHandler(catalogHandler.listDrugs),
  );
  // count route must be before /<id> wildcard
  router.get(
    '/v1/catalog/drugs/count',
    patientAuth.addHandler(catalogHandler.countDrugs),
  );
  router.get(
    '/v1/drugs/count',
    patientAuth.addHandler(catalogHandler.countDrugs),
  );
  // Drug CRUD — registered before /<id> wildcard; write ops require admin
  router.post(
    '/v1/catalog/drugs',
    adminOnly.addHandler(catalogHandler.createDrug),
  );
  router.put(
    '/v1/catalog/drugs/<id>',
    adminOnly.addHandler(
      (Request req) => catalogHandler.updateDrug(req, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/catalog/drugs/<id>',
    adminOnly.addHandler(
      (Request req) => catalogHandler.deleteDrug(req, req.params['id']!),
    ),
  );
  // Category-specific service routes — registered before /<id> wildcard
  // Slugs: dental, lab, procedures, imaging, laparoscopic, accommodation, consultation
  router.get(
    '/v1/catalog/services/<domain>',
    patientAuth.addHandler(
      (Request req) => catalogHandler.listByCategory(req, req.params['domain']!),
    ),
  );
  router.post(
    '/v1/catalog/services/<domain>',
    adminOnly.addHandler(
      (Request req) => catalogHandler.createService(req, req.params['domain']!),
    ),
  );
  router.put(
    '/v1/catalog/services/<domain>/<id>',
    adminOnly.addHandler(
      (Request req) => catalogHandler.updateService(req, req.params['domain']!, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/catalog/services/<domain>/<id>',
    adminOnly.addHandler(
      (Request req) => catalogHandler.deleteService(req, req.params['domain']!, req.params['id']!),
    ),
  );
  router.get(
    '/v1/catalog/<id>',
    patientAuth.addHandler(
      (Request req) => catalogHandler.getById(req, req.params['id']!),
    ),
  );
  // ── Ads (carousel content) ──────────────────────────────────────────────────
  // Admin-only, matching catalog's write-ops posture — this is content
  // management, not a day-to-day staff task.
  router.get('/v1/admin/ads', adminOnly.addHandler(adHandler.list));
  router.post('/v1/admin/ads', adminOnly.addHandler(adHandler.create));
  router.get(
    '/v1/admin/ads/<id>',
    adminOnly.addHandler(
      (Request req) => adHandler.getById(req, req.params['id']!),
    ),
  );
  router.put(
    '/v1/admin/ads/<id>',
    adminOnly.addHandler(
      (Request req) => adHandler.update(req, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/admin/ads/<id>',
    adminOnly.addHandler(
      (Request req) => adHandler.archive(req, req.params['id']!),
    ),
  );
  router.delete(
    '/v1/admin/ads/<id>/hard',
    adminOnly.addHandler(
      (Request req) => adHandler.hardDelete(req, req.params['id']!),
    ),
  );
  // Public — no auth. Mobile carousel reads this directly.
  router.get('/v1/ads', adHandler.listPublic);

  // Alias routes — app uses these shorter paths
  router.get('/v1/services', patientAuth.addHandler(catalogHandler.listServices));
  router.get('/v1/drugs', patientAuth.addHandler(catalogHandler.listDrugs));
  router.get(
    '/v1/services/<category>',
    patientAuth.addHandler(
      (Request req) => catalogHandler.listByCategory(req, req.params['category']!),
    ),
  );

  // ── Patient Auth (public) ─────────────────────────────────────────────────────
  router.post(
    '/v1/patient/auth/activate',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientAuthHandler.activate),
  );
  router.post(
    '/v1/patient/auth/login',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientAuthHandler.login),
  );
  router.post(
    '/v1/patient/auth/beneficiary-login',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientAuthHandler.beneficiaryLogin),
  );
  router.post(
    '/v1/patient/auth/refresh',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(refreshLimiter))
        .addHandler(patientAuthHandler.refresh),
  );
  router.post('/v1/patient/auth/logout', patientAuthHandler.logout);
  router.post(
    '/v1/patient/auth/change-password',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientAuthHandler.changePassword),
  );

  // ── Patient TOTP 2FA ──────────────────────────────────────────────────────────
  // setup/enable/disable require a normal patient session. verify-login is
  // pre-auth (called with a totp_challenge token, not a normal access
  // token) — patientAuth2 would reject it, so it only gets rate limiting.
  router.post(
    '/v1/patient/auth/totp/setup',
    Pipeline().addMiddleware(patientAuth2).addHandler(patientTotpHandler.setup),
  );
  router.post(
    '/v1/patient/auth/totp/enable',
    Pipeline()
        .addMiddleware(patientAuth2)
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientTotpHandler.enable),
  );
  router.post(
    '/v1/patient/auth/totp/disable',
    Pipeline()
        .addMiddleware(patientAuth2)
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientTotpHandler.disable),
  );
  router.post(
    '/v1/patient/auth/totp/verify-login',
    Pipeline()
        .addMiddleware(rateLimitMiddleware(loginLimiter))
        .addHandler(patientAuthHandler.verifyTotpLogin),
  );

  // ── Patient Deposits (MTN MoMo + Card) ───────────────────────────────────────
  // /deposit must be before /deposit/<id> to avoid the wildcard catching it.
  router.post(
    '/v1/patient/deposit',
    Pipeline().addMiddleware(patientAuth2).addHandler(depositHandler.initiate),
  );
  router.get(
    '/v1/patient/deposit/<id>',
    Pipeline().addMiddleware(patientAuth2).addHandler(
      (Request req) => depositHandler.getStatus(req, req.params['id']!),
    ),
  );
  router.post(
    '/v1/patient/deposit/<id>/reverse',
    Pipeline().addMiddleware(patientAuth2).addHandler(
      (Request req) => depositHandler.reverse(req, req.params['id']!),
    ),
  );

  // ── Patient Checkout (wallet spend/debit) ──────────────────────────────────────
  router.post(
    '/v1/patient/checkout',
    Pipeline().addMiddleware(patientAuth2).addHandler(checkoutHandler.checkout),
  );

  // ── Payment Provider Webhooks (no auth — verified by payload/header) ──────────
  router.post('/v1/webhooks/pesapal', depositHandler.pesapalIpn);
  router.post('/v1/kyc/webhook', kycHandler.webhook);

  // ── Patient KYC ──────────────────────────────────────────────────────────────
  router.post(
    '/v1/patient/kyc/submit',
    Pipeline().addMiddleware(patientAuth2).addHandler(kycHandler.submit),
  );
  router.get(
    '/v1/patient/kyc/status',
    Pipeline().addMiddleware(patientAuth2).addHandler(kycHandler.status),
  );

  // ── Patient self-service endpoints ────────────────────────────────────────────
  router.get(
    '/v1/patient/wallet',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patient = requirePatientUser(req);
      final wallet = await walletService.getWalletByPatient(patient.id);
      return okResponse(wallet);
    }),
  );

  router.get(
    '/v1/patient/me',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final patient = await patientRepo.findById(patientUser.id);
      if (patient == null) throw ApiError.notFound('Patient not found');
      return okResponse(patient);
    }),
  );

  // Self-service profile edit — deliberately routed to updateOwnProfile,
  // never the staff-facing update(), so a patient can't set account_type/
  // is_active/relationship/is_minor on themselves via this endpoint.
  router.patch(
    '/v1/patient/me',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final body = await parseJsonBody(req);
      final patient = await patientRepo.updateOwnProfile(
        patientUser.id,
        fullName: body['fullName'] as String?,
        phone: body['phone'] as String?,
        email: body['email'] as String?,
      );
      if (patient == null) throw ApiError.notFound('Patient not found');
      return okResponse(patient);
    }),
  );

  router.get(
    '/v1/patient/visits',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final qp = req.url.queryParameters;
      final limit = (int.tryParse(qp['limit'] ?? '20') ?? 20).clamp(1, 100);
      final offset = int.tryParse(qp['offset'] ?? '0') ?? 0;

      // A beneficiary sees only visits recorded for them — never the
      // primary's or a sibling's. The primary sees every visit on the
      // family account (their own + every beneficiary's): a beneficiary
      // may hide the `reason` on their own visit (never the whole entry),
      // which asPrimaryView enforces via redaction below — it does not
      // hide the visit from this list.
      final requester = await patientRepo.findById(patientUser.id);
      final isBeneficiary = isBeneficiaryRow(requester);

      final (encounters, total) = await encounterService.listEncounters(
        patientId: isBeneficiary ? null : patientUser.id,
        dependentId: isBeneficiary ? patientUser.id : null,
        excludeDependents: false,
        asPrimaryView: !isBeneficiary,
        limit: limit,
        offset: offset,
        dateFrom: qp['dateFrom'],
        dateTo: qp['dateTo'],
        search: qp['search'],
      );

      final visits = encounters.map((e) {
        final svcs = (e['services'] as List?)
            ?.map((s) => (s as Map<String, dynamic>)['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .join(', ');
        return {
          'visitId':        e['id'],
          'referenceValue': e['reference_number'] ?? '',
          'totalMinor':     (((e['total_cost'] as num?) ?? 0) * 100).toInt(),
          'currency':       'UGX',
          'services':       (svcs != null && svcs.isNotEmpty) ? svcs : null,
          'encounterRef':   null,
          'createdAt':      e['visited_at']?.toString() ?? e['created_at']?.toString() ?? '',
          'status':         e['status'] ?? '',
          'reason':         e['reason'],
          'reasonHidden':   e['reason_hidden'] == true,
        };
      }).toList();

      return Response.ok(
        jsonEncode({'data': {'visits': visits, 'total': total}}),
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  router.get(
    '/v1/patient/transactions',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final qp = req.url.queryParameters;
      final limit = (int.tryParse(qp['limit'] ?? '20') ?? 20).clamp(1, 100);
      final offset = int.tryParse(qp['offset'] ?? '0') ?? 0;

      final wallet = await walletRepo.findByPatientId(patientUser.id);
      if (wallet == null) {
        return Response.ok(
          jsonEncode({'data': {'transactions': [], 'total': 0}}),
          headers: {'content-type': 'application/json'},
        );
      }

      // A beneficiary sees only transactions they personally initiated
      // (their own checkouts); the primary holder keeps the full,
      // unfiltered shared-wallet history.
      final requester = await patientRepo.findById(patientUser.id);
      final isBeneficiary = isBeneficiaryRow(requester);

      final (entries, total) = await walletRepo.getLedger(
        wallet['id'] as String,
        limit: limit,
        offset: offset,
        initiatedByFilter: isBeneficiary ? patientUser.id : null,
      );

      final transactions = entries.map((e) {
        final type = (e['type'] as String? ?? '').toLowerCase();
        final encounterRef = e['encounter_reference'] as String?;
        return {
          'txId':           e['id'],
          'txType':         type.toUpperCase(),
          // Falls back to the raw type (deposit/deduction/reversal/…) when
          // there's no linked encounter — e.g. deposits, standalone checkouts.
          'referenceValue': (encounterRef != null && encounterRef.isNotEmpty) ? encounterRef : type,
          'totalMinor':     (((e['amount_shillings'] as num?) ?? 0) * 100).toInt(),
          'currency':       'UGX',
          'status':         (e['status'] as String?)?.toUpperCase() ?? 'POSTED',
          'createdAt':      e['created_at']?.toString() ?? '',
          // Null when this entry has no linked visit (deposit, standalone
          // checkout, or the source encounter has since been deleted).
          'encounterId':      e['encounter_id'],
          'encounterService': e['encounter_service_type'],
        };
      }).toList();

      return Response.ok(
        jsonEncode({'data': {'transactions': transactions, 'total': total}}),
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  // /v1/patient/beneficiaries reads/writes the current patients.primary_account_id
  // sub-account model via PatientHandler — NOT the legacy `dependents` table
  // (which findDependentsByWalletId queries and which the write paths below
  // never touch, so using it here would silently desync from what create/delete
  // actually persist).
  router.get(
    '/v1/patient/beneficiaries',
    Pipeline().addMiddleware(patientAuth2).addHandler(patientHandler.listBeneficiaries),
  );
  router.post(
    '/v1/patient/beneficiaries',
    Pipeline().addMiddleware(patientAuth2).addHandler(patientHandler.createBeneficiary),
  );
  router.post(
    '/v1/patient/beneficiaries/<id>/delete',
    Pipeline().addMiddleware(patientAuth2).addHandler(
      (Request req) => patientHandler.deleteBeneficiary(req, req.params['id']!),
    ),
  );
  router.post(
    '/v1/patient/beneficiaries/<id>/request-login',
    Pipeline().addMiddleware(patientAuth2).addHandler(
      (Request req) => patientHandler.requestBeneficiaryLoginAccess(req, req.params['id']!),
    ),
  );
  router.get(
    '/v1/patient/beneficiaries/<id>/visits',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final beneficiaryId = req.params['id']!;
      final beneficiary = await patientRepo.findById(beneficiaryId);
      if (beneficiary == null) throw ApiError.notFound('Beneficiary not found');
      if (beneficiary['primary_account_id'] != patientUser.id) {
        throw ApiError.forbidden();
      }
      final qp = req.url.queryParameters;
      final limit = (int.tryParse(qp['limit'] ?? '20') ?? 20).clamp(1, 100);
      final offset = int.tryParse(qp['offset'] ?? '0') ?? 0;

      final (encounters, total) = await encounterService.listEncounters(
        dependentId: beneficiaryId,
        // Adult beneficiary's reason redacts when hidden; a minor's never
        // does (asPrimaryView + is_minor check happens in the repository).
        asPrimaryView: true,
        limit: limit,
        offset: offset,
      );

      final visits = encounters.map((e) {
        final svcs = (e['services'] as List?)
            ?.map((s) => (s as Map<String, dynamic>)['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .join(', ');
        return {
          'visitId':        e['id'],
          'referenceValue': e['reference_number'] ?? '',
          'totalMinor':     (((e['total_cost'] as num?) ?? 0) * 100).toInt(),
          'currency':       'UGX',
          'services':       (svcs != null && svcs.isNotEmpty) ? svcs : null,
          'createdAt':      e['visited_at']?.toString() ?? e['created_at']?.toString() ?? '',
          'status':         e['status'] ?? '',
          'reason':         e['reason'],
          'reasonHidden':   e['reason_hidden'] == true,
        };
      }).toList();

      return Response.ok(
        jsonEncode({'data': {'visits': visits, 'total': total}}),
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  router.get(
    '/v1/patient/visits/<id>',
    Pipeline().addMiddleware(patientAuth2).addHandler((Request req) async {
      final patientUser = requirePatientUser(req);
      final requester = await patientRepo.findById(patientUser.id);
      final isBeneficiary = isBeneficiaryRow(requester);
      // asPrimaryView must be resolved before the fetch — it drives the
      // reason redaction inside getEncounter, same as the two list
      // endpoints. Passing it late would leak an unredacted reason.
      final encounter = await encounterService.getEncounter(
        req.params['id']!,
        asPrimaryView: !isBeneficiary,
      );
      // Ownership: a beneficiary only owns visits recorded FOR them
      // (dependent_id). The primary owns every visit on the family account —
      // their own AND every beneficiary's (matching /patient/visits' list
      // view) — so no dependent_id restriction here. Fail-fast 403 — never
      // a silent filter.
      final owns = isBeneficiary
          ? encounter['dependent_id'] == patientUser.id
          : encounter['patient_id'] == patientUser.id;
      if (!owns) throw ApiError.forbidden();
      return okResponse(encounter);
    }),
  );
  router.patch(
    '/v1/patient/visits/<id>/reason-hidden',
    Pipeline().addMiddleware(patientAuth2).addHandler(
      (Request req) => encounterHandler.setReasonHidden(req, req.params['id']!),
    ),
  );

  // ── Admin — Beneficiary login-access-request queue ────────────────────────────
  router.get(
    '/v1/admin/beneficiary-login-requests',
    adminOnly.addHandler(patientHandler.listLoginAccessRequests),
  );
  router.post(
    '/v1/admin/beneficiary-login-requests/<id>/reject',
    adminOnly.addHandler(
      (Request req) => patientHandler.rejectLoginAccessRequest(req, req.params['id']!),
    ),
  );

  // ── Admin — Patient Credential Management ─────────────────────────────────────
  router.post(
    '/v1/admin/patient-credentials/<patientId>/generate',
    adminOnly.addHandler(
      (Request req) => patientCredHandler.generate(req, req.params['patientId']!),
    ),
  );
  router.get(
    '/v1/admin/patient-credentials/<patientId>',
    adminOnly.addHandler(
      (Request req) => patientCredHandler.getCredentials(req, req.params['patientId']!),
    ),
  );
  router.post(
    '/v1/admin/patient-credentials/<patientId>/reset',
    adminOnly.addHandler(
      (Request req) => patientCredHandler.reset(req, req.params['patientId']!),
    ),
  );
  router.post(
    '/v1/admin/patient-credentials/<patientId>/suspend',
    adminOnly.addHandler(
      (Request req) => patientCredHandler.suspend(req, req.params['patientId']!),
    ),
  );
  router.post(
    '/v1/admin/patient-credentials/<patientId>/reinstate',
    adminOnly.addHandler(
      (Request req) => patientCredHandler.reinstate(req, req.params['patientId']!),
    ),
  );

  // ── Admin — Audit log ──────────────────────────────────────────────────────────
  router.get('/v1/admin/audit-log', adminOnly.addHandler(auditHandler.list));

  // ── Admin — PII encryption backfill ───────────────────────────────────────────
  router.post(
    '/v1/admin/patients/backfill-pii-encryption',
    adminOnly.addHandler(patientHandler.backfillPiiEncryption),
  );

  // ── Analytics ─────────────────────────────────────────────────────────────────
  router.get(
    '/v1/analytics/kpis',
    patientAuth.addHandler(analyticsHandler.getKpis),
  );
  router.get(
    '/v1/analytics/dashboard-kpis',
    patientAuth.addHandler(analyticsHandler.getDashboardKpis),
  );
  router.get(
    '/v1/analytics/beneficiary-login-stats',
    adminOnly.addHandler(analyticsHandler.getBeneficiaryLoginStats),
  );
  router.get(
    '/v1/analytics/visits/trend',
    patientAuth.addHandler(analyticsHandler.getVisitTrend),
  );
  router.get(
    '/v1/analytics/deposits-held',
    patientAuth.addHandler(analyticsHandler.getDepositsHeld),
  );
  router.post(
    '/v1/reports/generate',
    Pipeline()
        .addMiddleware(auth)
        .addMiddleware(rateLimitMiddleware(reportLimiter))
        .addHandler(analyticsHandler.generateReport),
  );

  // ── Global pipeline ───────────────────────────────────────────────────────────
  return Pipeline()
      .addMiddleware(requestIdMiddleware())
      .addMiddleware(rateLimitMiddleware(generalLimiter))
      .addMiddleware(_errorHandlingMiddleware())
      .addHandler(router.call);
}

Middleware _errorHandlingMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on ApiError catch (e) {
        final requestId = getRequestId(request);
        return errorResponse(e, requestId);
      } catch (e, stack) {
        log.severe('Unhandled error on ${request.method} ${request.url}', e, stack);
        final requestId = getRequestId(request);
        return errorResponse(ApiError.internal(), requestId);
      }
    };
  };
}
