// Migration runner — applies migrations/NNN_*.sql in number order and
// records each in schema_migrations, so what's applied is tracked instead
// of remembered.
//
//   dart run bin/migrate.dart --status          list applied / pending
//   dart run bin/migrate.dart                    apply every pending migration
//   dart run bin/migrate.dart --baseline 044     record 001–044 as applied
//                                                WITHOUT running them (one-off,
//                                                for migrations applied by hand)
//
// Connects with the same DB_* settings as the API (.env or environment).
// Stops at the first failing statement without recording that migration.
// MariaDB can't roll back DDL, so a failed migration may be half-applied —
// every migration from 044 on is written to be safely re-run.
import 'dart:io';

import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/database/sql_script.dart';

Future<void> main(List<String> args) async {
  AppConfig.load();
  final pool = MySQLConnectionPool(
    host: AppConfig.dbHost,
    port: AppConfig.dbPort,
    userName: AppConfig.dbUser,
    password: AppConfig.dbPassword,
    databaseName: AppConfig.dbName,
    maxConnections: 1,
  );
  try {
    exitCode = await run(pool, args, Directory('migrations'));
  } finally {
    await pool.close();
  }
}

Future<int> run(MySQLConnectionPool pool, List<String> args, Directory dir) async {
  await pool.execute(
    'CREATE TABLE IF NOT EXISTS schema_migrations ('
    'version VARCHAR(255) NOT NULL PRIMARY KEY, '
    'applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)',
  );
  final applied = {
    for (final r in (await pool.execute('SELECT version FROM schema_migrations')).rows)
      r.colAt(0)!,
  };
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => migrationNumber(_name(f)) != null && f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => migrationNumber(_name(a))!.compareTo(migrationNumber(_name(b))!));

  if (args.contains('--status')) {
    for (final f in files) {
      stdout.writeln('${applied.contains(_name(f)) ? 'applied' : 'PENDING'}  ${_name(f)}');
    }
    return 0;
  }

  final baselineAt = args.indexOf('--baseline');
  if (baselineAt != -1) {
    final upTo = baselineAt + 1 < args.length ? int.tryParse(args[baselineAt + 1]) : null;
    if (upTo == null) {
      stderr.writeln('Usage: --baseline <migration number>');
      return 64;
    }
    for (final f in files.where((f) => migrationNumber(_name(f))! <= upTo)) {
      await pool.execute(
        'INSERT IGNORE INTO schema_migrations (version) VALUES (:v)',
        {'v': _name(f)},
      );
      stdout.writeln('recorded  ${_name(f)} (not run)');
    }
    return 0;
  }

  final pending = files.where((f) => !applied.contains(_name(f))).toList();
  if (pending.isEmpty) {
    stdout.writeln('Nothing to apply — database is up to date.');
    return 0;
  }
  for (final f in pending) {
    final statements = splitSqlScript(f.readAsStringSync());
    stdout.writeln('applying  ${_name(f)} (${statements.length} statements)');
    for (var i = 0; i < statements.length; i++) {
      try {
        await pool.execute(statements[i]);
      } catch (e) {
        stderr.writeln('FAILED    ${_name(f)} at statement ${i + 1}: $e');
        stderr.writeln('          Not recorded. Fix the cause and run again.');
        return 1;
      }
    }
    await pool.execute(
      'INSERT INTO schema_migrations (version) VALUES (:v)',
      {'v': _name(f)},
    );
    stdout.writeln('applied   ${_name(f)}');
  }
  return 0;
}

String _name(File f) => f.uri.pathSegments.last;
