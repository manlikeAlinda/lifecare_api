// Fixtures for the database-backed tests in this folder.
//
// They run only when LIFECARE_TEST_DB is set, e.g.
//   LIFECARE_TEST_DB=127.0.0.1:3307:root:secret:lc_test dart test test/integration
// pointing at a SCRATCH MariaDB loaded with the production schema and all
// migrations — never production (every test writes rows).
import 'dart:io';

import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

/// Null (tests skip) unless LIFECARE_TEST_DB is set.
String? get testDbSkipReason => Platform.environment['LIFECARE_TEST_DB'] == null
    ? 'Set LIFECARE_TEST_DB=host:port:user:password:database (scratch DB only)'
    : null;

MySQLConnectionPool openTestPool() {
  final parts = Platform.environment['LIFECARE_TEST_DB']!.split(':');
  AppConfig.loadFromMap({
    'DB_USER': parts[2],
    'DB_PASSWORD': parts[3],
    'PII_ENCRYPTION_KEY': '',
    'JWT_SECRET': 'integration-test-secret-integration-test-secret',
  });
  return MySQLConnectionPool(
    host: parts[0],
    port: int.parse(parts[1]),
    userName: parts[2],
    password: parts[3],
    databaseName: parts[4],
    maxConnections: 3,
    secure: false,
  );
}

String uniqueTag() => generateUuid().substring(0, 8);

Future<String> insertUser(MySQLConnectionPool pool) async {
  final id = generateUuid();
  await pool.execute(
    'INSERT INTO users (user_id, username, display_name, password_hash, password_alg) '
    "VALUES (${uuidParam('id')}, :u, 'Test Cashier', 'x', 'bcrypt')",
    {'id': id, 'u': 'it_${uniqueTag()}'},
  );
  return id;
}

Future<String> insertPatient(
  MySQLConnectionPool pool, {
  String type = 'individual',
  String? primary,
  String? phone,
}) async {
  final id = generateUuid();
  await pool.execute(
    'INSERT INTO patients (patient_id, patient_code, full_name, account_type, '
    'primary_account_id, phone_e164, is_active) VALUES '
    "(${uuidParam('id')}, :code, 'Test Patient', :type, "
    "${primary == null ? 'NULL' : uuidParam('primary')}, :phone, 1)",
    {
      'id': id,
      'code': 'IT-${uniqueTag()}',
      'type': type,
      if (primary != null) 'primary': primary,
      'phone': phone,
    },
  );
  return id;
}

Future<String> insertWallet(
  MySQLConnectionPool pool,
  String patientId, {
  int balance = 0,
  String status = 'ACTIVE',
}) async {
  final id = generateUuid();
  await pool.execute(
    'INSERT INTO wallets (wallet_id, primary_patient_id, patient_id, balance_minor, '
    'balance_shillings, status) VALUES '
    "(${uuidParam('id')}, ${uuidParam('p')}, ${uuidParam('p')}, 0, :b, :s)",
    {'id': id, 'p': patientId, 'b': balance, 's': status},
  );
  return id;
}

Future<int> insertDrug(MySQLConnectionPool pool, {int rate = 5000}) async {
  await pool.execute(
    "INSERT INTO drugs (drug_name, drug_type, rate, currency, is_active) "
    "VALUES (:n, 'Drugs', :r, 'UGX', 1)",
    {'n': 'Test drug ${uniqueTag()}', 'r': rate},
  );
  return int.parse(await scalar(pool, 'SELECT MAX(drug_id) FROM drugs') ?? '0');
}

Future<String?> scalar(MySQLConnectionPool pool, String sql,
        [Map<String, dynamic> params = const {}]) async =>
    (await pool.execute(sql, params)).rows.first.colAt(0);

Future<int> walletBalance(MySQLConnectionPool pool, String walletId) async =>
    int.parse((await scalar(pool,
        "SELECT balance_shillings FROM wallets WHERE ${uuidWhere('wallet_id', 'w')}",
        {'w': walletId}))!);
