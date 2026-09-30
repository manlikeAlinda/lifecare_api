// Database-backed tests for every path that moves money. Skipped unless
// LIFECARE_TEST_DB is set — see db_fixture.dart.
@Tags(['db'])
library;

import 'dart:convert';

import 'package:mysql_client/mysql_client.dart';
import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/services/pii_encryption_service.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'package:lifecare_api/modules/catalog/catalog_repository.dart';
import 'package:lifecare_api/modules/deposits/deposit_repository.dart';
import 'package:lifecare_api/modules/encounters/encounter_repository.dart';
import 'package:lifecare_api/modules/encounters/encounter_service.dart';
import 'package:lifecare_api/modules/patients/patient_repository.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'package:lifecare_api/modules/wallets/wallet_service.dart';
import 'db_fixture.dart';

void main() {
  if (testDbSkipReason != null) {
    test('money paths against a real database', () {}, skip: testDbSkipReason);
    return;
  }

  late MySQLConnectionPool pool;
  late WalletService wallets;
  late EncounterService visits;
  late String staff;

  setUpAll(() async {
    pool = openTestPool();
    final walletRepo = WalletRepository(pool);
    wallets = WalletService(walletRepo);
    visits = EncounterService(
      EncounterRepository(pool),
      walletRepo,
      PatientRepository(pool, PiiEncryptionService(), walletRepo),
      CatalogRepository(pool),
    );
    staff = await insertUser(pool);
  });

  tearDownAll(() => pool.close());

  group('desk payment', () {
    test('credits the wallet, records method and cashier, audits', () async {
      final patient = await insertPatient(pool);
      final wallet = await insertWallet(pool, patient, balance: -10000);
      final res = await wallets.recordCounterPayment(wallet,
          {'amount': 15000, 'payment_method': 'cash', 'payment_reference': 'R-1'}, staff);
      expect(res['balance_shillings'], 5000);
      expect(await walletBalance(pool, wallet), 5000);
      final row = (await pool.execute(
        'SELECT payment_method, payment_reference, LOWER(HEX(initiated_by)) cashier '
        "FROM wallet_ledger WHERE ${uuidWhere('wallet_id', 'w')}", {'w': wallet},
      )).rows.single.assoc();
      expect(row['payment_method'], 'cash');
      expect(row['payment_reference'], 'R-1');
      expect(row['cashier'], staff.replaceAll('-', ''));
      expect(await scalar(pool,
          "SELECT COUNT(*) FROM audit_log WHERE action = 'COUNTER_PAYMENT' "
          "AND ${uuidWhere('target_id', 'w')}", {'w': wallet}), '1');
    });

    test('a closed wallet is refused and nothing is written', () async {
      final wallet = await insertWallet(pool, await insertPatient(pool), status: 'CLOSED');
      await expectLater(
        wallets.recordCounterPayment(wallet, {'amount': 1000, 'payment_method': 'cash'}, staff),
        throwsA(isA<ApiError>()),
      );
      expect(await scalar(pool,
          "SELECT COUNT(*) FROM wallet_ledger WHERE ${uuidWhere('wallet_id', 'w')}",
          {'w': wallet}), '0');
    });

    test('a retried payment (same key) is credited once', () async {
      final wallet = await insertWallet(pool, await insertPatient(pool));
      final key = generateUuid();
      final body = {'amount': 5000, 'payment_method': 'mobile_money', 'idempotency_key': key};
      final a = await wallets.recordCounterPayment(wallet, body, staff);
      final b = await wallets.recordCounterPayment(wallet, body, staff);
      expect(b['ledger_id'], a['ledger_id']);
      expect(b['replayed'], isTrue);
      expect(await walletBalance(pool, wallet), 5000);
    });
  });

  group('visit charge', () {
    test('charges the wallet once even when resubmitted, including concurrently', () async {
      final patient = await insertPatient(pool);
      final wallet = await insertWallet(pool, patient, balance: 100000);
      final drug = await insertDrug(pool, rate: 7000);
      Map<String, dynamic> visit(String key) => {
            'patient_id': patient,
            'reference_number': 'IT',
            'drug_lines': [{'drug_id': drug, 'quantity': 2}],
            'idempotency_key': key,
          };
      final key = generateUuid();
      final first = await visits.createEncounter(visit(key), staff);
      final again = await visits.createEncounter(visit(key), staff);
      expect(again['id'], first['id']);
      expect(await walletBalance(pool, wallet), 86000);

      final raceKey = generateUuid();
      final raced = await Future.wait([
        visits.createEncounter(visit(raceKey), staff),
        visits.createEncounter(visit(raceKey), staff),
      ]);
      expect(raced[0]['id'], raced[1]['id']);
      expect(await walletBalance(pool, wallet), 72000);
    });

    test('a visit may put the wallet into debt (negative-balance rule)', () async {
      final patient = await insertPatient(pool);
      final wallet = await insertWallet(pool, patient);
      final drug = await insertDrug(pool, rate: 3000);
      await visits.createEncounter({
        'patient_id': patient,
        'drug_lines': [{'drug_id': drug, 'quantity': 1}],
      }, staff);
      expect(await walletBalance(pool, wallet), -3000);
    });
  });

  group('visit delete', () {
    test('refunds, archives the full visit and audits what it was', () async {
      final patient = await insertPatient(pool);
      final wallet = await insertWallet(pool, patient, balance: 50000);
      final drug = await insertDrug(pool, rate: 3000);
      final visit = await visits.createEncounter({
        'patient_id': patient,
        'reference_number': 'DEL',
        'drug_lines': [{'drug_id': drug, 'quantity': 3}],
      }, staff);
      final id = visit['id'] as String;

      expect(await visits.deleteEncounter(id, staff), isTrue);
      expect(await walletBalance(pool, wallet), 50000);
      final snapshot = jsonDecode((await scalar(pool,
          "SELECT snapshot FROM deleted_encounters WHERE ${uuidWhere('encounter_id', 'id')}",
          {'id': id}))!) as Map<String, dynamic>;
      expect(snapshot['reference_number'], 'DEL');
      expect(snapshot['medications'], hasLength(1));
      final audit = jsonDecode((await scalar(pool,
          "SELECT details FROM audit_log WHERE action = 'DELETE_ENCOUNTER' "
          "AND ${uuidWhere('target_id', 'id')}", {'id': id}))!) as Map<String, dynamic>;
      expect((audit['before'] as Map)['reference_number'], 'DEL');
    });
  });

  group('Pesapal deposit', () {
    test('credits once with the reported method, however often it is confirmed', () async {
      final patient = await insertPatient(pool);
      final wallet = await insertWallet(pool, patient);
      final repo = DepositRepository(pool);
      final depositId = generateUuid();
      await repo.create(depositId: depositId, walletId: wallet, patientId: patient,
          amountShillings: 20000, paymentMethod: 'PESAPAL');
      Future<bool> confirm() => repo.creditDepositTransaction(depositId: depositId,
          walletId: wallet, patientId: patient, amountShillings: 20000,
          paymentMethod: 'card');
      expect(await confirm(), isTrue);
      expect(await confirm(), isFalse);
      expect(await walletBalance(pool, wallet), 20000);
      expect(await scalar(pool,
          "SELECT payment_method FROM wallet_ledger WHERE ${uuidWhere('wallet_id', 'w')}",
          {'w': wallet}), 'card');
    });
  });
}
