import 'dart:async';
import 'dart:io';
import 'package:lifecare_api/app.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/database/database.dart';
import 'package:lifecare_api/core/logging/logger.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

void main() {
  runZonedGuarded(_start, (error, stack) {
    // Catches unhandled async errors (e.g. idle MySQL connections reset by
    // Hostinger's ~20s server-side timeout) and logs them without killing
    // the process. The pool will open a fresh connection on the next request.
    log.severe('Uncaught async error (process kept alive): $error', error, stack);
  });
}

Future<void> _start() async {
  setupLogging();

  log.info('Starting LifeCare API...');

  AppConfig.load();

  await Database.init();

  final handler = buildApp();

  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    AppConfig.port,
  );

  server.autoCompress = true;

  log.info('LifeCare API listening on http://0.0.0.0:${server.port}');
  log.info('Environment: ${AppConfig.appEnv}');

  // Graceful shutdown on SIGINT / SIGTERM
  Future<void> shutdown(_) async {
    log.info('Shutdown signal received. Closing...');
    await server.close(force: false);
    await Database.close();
    log.info('Shutdown complete.');
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);

  // SIGTERM is not available on Windows, guard it
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}
