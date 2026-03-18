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
    );
    log.info('Database pool initialized (${AppConfig.dbHost}:${AppConfig.dbPort}/${AppConfig.dbName})');
  }

  static MySQLConnectionPool get pool => _pool;

  static Future<void> close() async {
    await _pool.close();
    log.info('Database pool closed');
  }
}
