import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:lifecare_api/core/database/database.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/logging/logger.dart';
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
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_handler.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_repository.dart';
import 'package:lifecare_api/modules/patient_credentials/patient_credentials_service.dart';
import 'package:lifecare_api/core/services/email_service.dart';

Handler buildApp() {
  final pool = Database.pool;

  // ── Repositories ────────────────────────────────────────────────────────────
  final authRepo = AuthRepository(pool);
  final userRepo = UserRepository(pool);
  final patientRepo = PatientRepository(pool);
  final walletRepo = WalletRepository(pool);
  final encounterRepo = EncounterRepository(pool);
  final catalogRepo = CatalogRepository(pool);
  final analyticsRepo = AnalyticsRepository(pool);
  final patientAuthRepo = PatientAuthRepository(pool);
  final patientCredRepo = PatientCredentialsRepository(pool);

  // ── Services ────────────────────────────────────────────────────────────────
  final authService = AuthService(authRepo);
  final userService = UserService(userRepo);
  final patientService = PatientService(patientRepo);
  final walletService = WalletService(walletRepo);
  final encounterService = EncounterService(encounterRepo, walletRepo);
  final catalogService = CatalogService(catalogRepo);
  final analyticsService = AnalyticsService(analyticsRepo);
  final emailService = EmailService();
  final patientAuthService = PatientAuthService(patientAuthRepo, authService);
  final patientCredService = PatientCredentialsService(patientCredRepo, emailService);

  // ── Handlers ─────────────────────────────────────────────────────────────────
  final authHandler = AuthHandler(authService);
  final userHandler = UserHandler(userService);
  final patientHandler = PatientHandler(patientService);
  final walletHandler = WalletHandler(walletService);
  final encounterHandler = EncounterHandler(encounterService);
  final catalogHandler = CatalogHandler(catalogService);
  final analyticsHandler = AnalyticsHandler(analyticsService);
  final patientAuthHandler = PatientAuthHandler(patientAuthService);
  final patientCredHandler = PatientCredentialsHandler(patientCredService);

  // ── Middleware pipelines ─────────────────────────────────────────────────────
  final auth = authMiddleware();
  final adminOnly = Pipeline().addMiddleware(auth).addMiddleware(requireAdmin());

  // ── Router ───────────────────────────────────────────────────────────────────
  final router = Router();

  // Health check (public)
  router.get('/health', (Request _) => Response.ok('{"status":"ok"}',
      headers: {'content-type': 'application/json'}));

  // DB diagnostic (public, temporary — remove after confirming DB connects)
  router.get('/diag/db', (Request _) async {
    try {
      await Database.pool.execute('SELECT 1');
      return Response.ok('{"db":"ok"}',
          headers: {'content-type': 'application/json'});
    } catch (e) {
      final detail = e.toString().replaceAll('"', "'");
      return Response.internalServerError(
        body: '{"db":"error","detail":"$detail"}',
        headers: {'content-type': 'application/json'},
      );
    }
  });

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

  // ── Users (admin only for create/delete/role; auth for read/update/password) ─
  router.get(
    '/v1/users',
    Pipeline().addMiddleware(auth).addHandler(userHandler.list),
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
    patientAuth.addHandler(
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
        final (encounters, total) = await encounterService.listEncounters(
          patientId: id,
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
    patientAuth.addHandler(
      (Request req) =>
          patientHandler.deleteDependent(req, req.params['patientId']!, req.params['depId']!),
    ),
  );

  // ── Wallets ───────────────────────────────────────────────────────────────────
  router.get('/v1/wallets', patientAuth.addHandler(walletHandler.list));
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
    patientAuth.addHandler(
      (Request req) => walletHandler.createTransaction(req, req.params['id']!),
    ),
  );

  // ── Encounters ────────────────────────────────────────────────────────────────
  router.get('/v1/encounters', patientAuth.addHandler(encounterHandler.list));
  router.post('/v1/encounters', patientAuth.addHandler(encounterHandler.create));
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
    patientAuth.addHandler(
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
  // Category-specific service routes — registered before /<id> wildcard
  // Slugs: dental, lab, procedures, imaging, laparoscopic, accommodation, consultation
  router.get(
    '/v1/catalog/services/<domain>',
    patientAuth.addHandler(
      (Request req) => catalogHandler.listByCategory(req, req.params['domain']!),
    ),
  );
  router.get(
    '/v1/catalog/<id>',
    patientAuth.addHandler(
      (Request req) => catalogHandler.getById(req, req.params['id']!),
    ),
  );
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
  router.post('/v1/patient-auth/activate', patientAuthHandler.activate);
  router.post('/v1/patient-auth/login', patientAuthHandler.login);
  router.post('/v1/patient-auth/refresh', patientAuthHandler.refresh);
  router.post('/v1/patient-auth/logout', patientAuthHandler.logout);
  router.post('/v1/patient-auth/change-password', patientAuthHandler.changePassword);

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

  // ── Analytics ─────────────────────────────────────────────────────────────────
  router.get(
    '/v1/analytics/kpis',
    patientAuth.addHandler(analyticsHandler.getKpis),
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
        log.severe('Unhandled error', e, stack);
        final requestId = getRequestId(request);
        return errorResponse(ApiError.internal(), requestId);
      }
    };
  };
}
