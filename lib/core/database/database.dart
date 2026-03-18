import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

class Database {
  static late MySQLConnectionPool _pool;

  static Future<void> init() async {
    _pool = MySQLConnectionPool(
      host: AppConfig.dbHost,
      port: AppConfig.dbPort,
      userName: AppConfig.dbUser,
      password: AppConfig.dbPassword,
      databaseName: AppConfig.dbName,
      maxConnections: AppConfig.dbPoolSize,
      secure: true,
    );
    log.info('Database pool created — testing connection to ${AppConfig.dbHost}:${AppConfig.dbPort}/${AppConfig.dbName}');
    try {
      await _pool.execute('SELECT 1');
      log.info('Database connection OK');
    } catch (e) {
      log.severe('Database connection FAILED: $e');
      rethrow;
    }
  }

  static MySQLConnectionPool get pool => _pool;

  static Future<void> close() async {
    await _pool.close();
    log.info('Database pool closed');
  }
}
