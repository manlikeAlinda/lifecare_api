import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'report_logic.dart';

/// SQL for the /v1/reports/* endpoints. Every query excludes soft-deleted
/// patients (deleted_at IS NULL) — see ReportsService for pagination and
/// the in-Dart aggregation that needs the full filtered set.
///
/// Beneficiaries share their primary account's wallet, so wallet-based
/// reports (debtors, deposits) are per primary account; a beneficiary's
/// visits carry patient_id = primary and dependent_id = beneficiary.
class ReportsRepository {
  final MySQLConnectionPool _pool;

  ReportsRepository(this._pool);

  Future<List<Map<String, String?>>> _query(
    String sql,
    Map<String, dynamic> params,
  ) async {
    final result = await _pool.execute(sql, params);
    return result.rows.map((r) => r.assoc()).toList();
  }

  static String _sqlTime(DateTime utc) =>
      utc.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

  // A person's visits: their own (dependent_id = them, for a beneficiary) or,
  // for a primary account holder, every visit on their account — which
  // includes their beneficiaries' visits (rolled up to the account).
  static String _personVisitWhere(String alias) =>
      "(${uuidWhere('$alias.patient_id', 'personId')} "
      "OR ${uuidWhere('$alias.dependent_id', 'personId')})";

  // ── Debtors ────────────────────────────────────────────────────────────────

  Future<List<Map<String, String?>>> debtorWallets() => _query(
        'SELECT ${uuidSelect('w.wallet_id', 'wallet_id')}, '
        "${uuidSelect('p.patient_id', 'patient_id')}, "
        'p.patient_code, p.full_name, p.phone_e164, '
        '-w.balance_shillings AS owed_shillings '
        'FROM wallets w '
        'JOIN patients p ON p.patient_id = w.primary_patient_id '
        'WHERE w.balance_shillings < 0 '
        "AND w.status NOT IN ('CLOSED', 'BLOCKED') "
        'AND p.deleted_at IS NULL',
        {},
      );

  /// Full ledger of every debtor wallet in one query (not one per wallet),
  /// ordered for debtSummary's chronological walk.
  Future<List<Map<String, String?>>> debtorLedger() => _query(
        'SELECT ${uuidSelect('l.wallet_id', 'wallet_id')}, '
        'l.type, l.amount_shillings, l.created_at '
        'FROM wallet_ledger l '
        'JOIN wallets w ON w.wallet_id = l.wallet_id '
        'WHERE w.balance_shillings < 0 '
        "AND w.status NOT IN ('CLOSED', 'BLOCKED') "
        'ORDER BY l.wallet_id, l.created_at, l.ledger_id',
        {},
      );

  // ── Deposits ───────────────────────────────────────────────────────────────

  // How the deposit was paid (wallet_ledger.payment_method, migration 046).
  // Rows written before that migration have no method and are reported as
  // 'not_recorded' rather than guessed.
  static const _depositMethodSql = "COALESCE(l.payment_method, 'not_recorded')";

  String _depositsFrom({
    required bool personScoped,
    required bool hasMethod,
  }) =>
      'FROM wallet_ledger l '
      'JOIN wallets w ON w.wallet_id = l.wallet_id '
      'JOIN patients p ON p.patient_id = w.primary_patient_id '
      'LEFT JOIN users u ON u.user_id = l.initiated_by '
      'LEFT JOIN patients ip ON ip.patient_id = l.initiated_by '
      "WHERE l.type = 'deposit' "
      'AND p.deleted_at IS NULL '
      'AND l.created_at >= :from AND l.created_at < :to '
      'AND l.amount_shillings >= :minAmount '
      '${hasMethod ? 'AND $_depositMethodSql = :method ' : ''}'
      '${personScoped ? 'AND w.primary_patient_id = '
          '(SELECT COALESCE(x.primary_account_id, x.patient_id) FROM patients x '
          "WHERE ${uuidWhere('x.patient_id', 'personId')}) " : ''}';

  Map<String, dynamic> _depositParams(
    ClinicDateRange range,
    int minAmount,
    String? method,
    String? personId,
  ) =>
      {
        'from': _sqlTime(range.fromUtc),
        'to': _sqlTime(range.toUtc),
        'minAmount': minAmount,
        if (method != null) 'method': method,
        if (personId != null) 'personId': personId,
      };

  Future<List<Map<String, String?>>> deposits({
    required ClinicDateRange range,
    required int minAmount,
    String? method,
    String? personId,
    required int limit,
    required int offset,
  }) =>
      _query(
        'SELECT ${uuidSelect('l.ledger_id', 'transaction_id')}, '
        'p.patient_code, p.full_name, l.amount_shillings, l.created_at, '
        '$_depositMethodSql AS method, l.payment_reference, '
        'COALESCE(u.display_name, ip.full_name) AS processed_by '
        '${_depositsFrom(personScoped: personId != null, hasMethod: method != null)}'
        'ORDER BY l.created_at DESC, l.ledger_id '
        'LIMIT :limit OFFSET :offset',
        {
          ..._depositParams(range, minAmount, method, personId),
          'limit': limit,
          'offset': offset,
        },
      );

  Future<List<Map<String, String?>>> depositTotalsByMethod({
    required ClinicDateRange range,
    required int minAmount,
    String? method,
    String? personId,
  }) =>
      _query(
        'SELECT $_depositMethodSql AS method, COUNT(*) AS count, '
        'COALESCE(SUM(l.amount_shillings), 0) AS total_shillings '
        '${_depositsFrom(personScoped: personId != null, hasMethod: method != null)}'
        'GROUP BY method',
        _depositParams(range, minAmount, method, personId),
      );

  // ── New accounts ───────────────────────────────────────────────────────────

  Future<List<Map<String, String?>>> newAccounts(ClinicDateRange range) => _query(
        // 'Registered by' lives only in audit_log (patients has no
        // created_by). The derived table is bounded by the same created_at
        // window (+1 day of slack for the audit write landing just after
        // the patient row) so it uses audit_log's created_at index instead
        // of scanning the whole log.
        'SELECT ${uuidSelect('p.patient_id', 'patient_id')}, '
        'p.patient_code, p.full_name, p.account_type, p.created_at, '
        'pp.full_name AS primary_name, u.display_name AS registered_by '
        'FROM patients p '
        'LEFT JOIN patients pp ON pp.patient_id = p.primary_account_id '
        'LEFT JOIN ('
        '  SELECT target_id, MIN(actor_user_id) AS actor_user_id FROM audit_log '
        "  WHERE action = 'create_patient' "
        '  AND created_at >= :from AND created_at < DATE_ADD(:to, INTERVAL 1 DAY) '
        '  GROUP BY target_id'
        ') a ON a.target_id = p.patient_id '
        'LEFT JOIN users u ON u.user_id = a.actor_user_id '
        'WHERE p.deleted_at IS NULL '
        'AND p.created_at >= :from AND p.created_at < :to '
        'ORDER BY p.created_at DESC',
        {'from': _sqlTime(range.fromUtc), 'to': _sqlTime(range.toUtc)},
      );

  // ── Inactive accounts ──────────────────────────────────────────────────────

  /// Every primary account with its family's latest visit, wallet
  /// transaction and mobile login (beneficiary activity rolls up to the
  /// primary). Aggregated once per source table, not per account.
  Future<List<Map<String, String?>>> accountActivity() => _query(
        'SELECT ${uuidSelect('p.patient_id', 'patient_id')}, '
        'p.patient_code, p.full_name, p.account_type, p.is_active, p.created_at, '
        'p.phone_e164, v.last_visit_at, t.last_transaction_at, s.last_login_at '
        'FROM patients p '
        'LEFT JOIN (SELECT patient_id, MAX(visited_at) AS last_visit_at '
        '  FROM encounters GROUP BY patient_id) v ON v.patient_id = p.patient_id '
        'LEFT JOIN (SELECT w.primary_patient_id AS pid, MAX(l.created_at) AS last_transaction_at '
        '  FROM wallet_ledger l JOIN wallets w ON w.wallet_id = l.wallet_id '
        '  GROUP BY w.primary_patient_id) t ON t.pid = p.patient_id '
        'LEFT JOIN (SELECT COALESCE(m.primary_account_id, m.patient_id) AS pid, '
        '  MAX(COALESCE(ps.last_used_at, ps.created_at)) AS last_login_at '
        '  FROM patient_sessions ps JOIN patients m ON m.patient_id = ps.patient_id '
        '  GROUP BY pid) s ON s.pid = p.patient_id '
        'WHERE p.deleted_at IS NULL '
        "AND p.primary_account_id IS NULL AND p.account_type <> 'dependent'",
        {},
      );

  // ── Drugs dispensed ────────────────────────────────────────────────────────

  String _drugsFrom({required bool hasDrug, required bool personScoped}) =>
      'FROM encounter_medications em '
      'JOIN encounters e ON e.encounter_id = em.encounter_id '
      'JOIN patients p ON p.patient_id = e.patient_id '
      'LEFT JOIN patients d ON d.patient_id = e.dependent_id '
      "WHERE e.status <> 'cancelled' AND p.deleted_at IS NULL "
      'AND e.visited_at >= :from AND e.visited_at < :to '
      '${hasDrug ? 'AND em.drug_id = :drugId ' : ''}'
      '${personScoped ? 'AND ${_personVisitWhere('e')} ' : ''}';

  Map<String, dynamic> _visitParams(
    ClinicDateRange range, {
    String? personId,
    Map<String, dynamic> extra = const {},
  }) =>
      {
        'from': _sqlTime(range.fromUtc),
        'to': _sqlTime(range.toUtc),
        if (personId != null) 'personId': personId,
        ...extra,
      };

  Future<List<Map<String, String?>>> drugLines({
    required ClinicDateRange range,
    int? drugId,
    String? personId,
    required int limit,
    required int offset,
  }) =>
      _query(
        'SELECT e.visited_at, e.reference_number, p.patient_code, '
        'p.full_name AS account_name, d.full_name AS beneficiary_name, '
        'em.drug_id, em.medication_name, em.quantity, em.rate, '
        '(em.quantity * em.rate) AS line_total '
        '${_drugsFrom(hasDrug: drugId != null, personScoped: personId != null)}'
        'ORDER BY e.visited_at DESC, em.id '
        'LIMIT :limit OFFSET :offset',
        _visitParams(range, personId: personId, extra: {
          if (drugId != null) 'drugId': drugId,
          'limit': limit,
          'offset': offset,
        }),
      );

  Future<List<Map<String, String?>>> drugTotals({
    required ClinicDateRange range,
    int? drugId,
    String? personId,
  }) =>
      _query(
        'SELECT em.drug_id, MAX(em.medication_name) AS medication_name, '
        'COUNT(*) AS line_count, COALESCE(SUM(em.quantity), 0) AS quantity, '
        'COALESCE(SUM(em.quantity * em.rate), 0) AS total_shillings '
        '${_drugsFrom(hasDrug: drugId != null, personScoped: personId != null)}'
        'GROUP BY em.drug_id ORDER BY total_shillings DESC',
        _visitParams(range, personId: personId, extra: {
          if (drugId != null) 'drugId': drugId,
        }),
      );

  // ── Services (one parameterised query for every service) ──────────────────

  String _servicesFrom({
    required bool hasDomain,
    required bool hasItem,
    required bool personScoped,
  }) =>
      'FROM encounter_services es '
      'JOIN encounters e ON e.encounter_id = es.encounter_id '
      'JOIN patients p ON p.patient_id = e.patient_id '
      'LEFT JOIN patients d ON d.patient_id = e.dependent_id '
      "WHERE e.status <> 'cancelled' AND p.deleted_at IS NULL "
      'AND e.visited_at >= :from AND e.visited_at < :to '
      '${hasDomain ? 'AND es.domain = :domain ' : ''}'
      '${hasItem ? 'AND es.domain_item_id = :itemId ' : ''}'
      '${personScoped ? 'AND ${_personVisitWhere('e')} ' : ''}';

  Future<List<Map<String, String?>>> serviceLines({
    required ClinicDateRange range,
    String? domain,
    int? itemId,
    String? personId,
    required int limit,
    required int offset,
  }) =>
      _query(
        'SELECT e.visited_at, e.reference_number, p.patient_code, '
        'p.full_name AS account_name, d.full_name AS beneficiary_name, '
        'es.domain, es.domain_item_id, es.service_name, es.quantity, es.price, '
        '(es.quantity * es.price) AS line_total '
        '${_servicesFrom(hasDomain: domain != null, hasItem: itemId != null, personScoped: personId != null)}'
        'ORDER BY e.visited_at DESC, es.id '
        'LIMIT :limit OFFSET :offset',
        _visitParams(range, personId: personId, extra: {
          if (domain != null) 'domain': domain,
          if (itemId != null) 'itemId': itemId,
          'limit': limit,
          'offset': offset,
        }),
      );

  Future<List<Map<String, String?>>> serviceTotals({
    required ClinicDateRange range,
    String? domain,
    int? itemId,
    String? personId,
  }) =>
      _query(
        'SELECT es.domain, es.service_name, COUNT(*) AS line_count, '
        'COALESCE(SUM(es.quantity * es.price), 0) AS total_shillings '
        '${_servicesFrom(hasDomain: domain != null, hasItem: itemId != null, personScoped: personId != null)}'
        'GROUP BY es.domain, es.service_name ORDER BY total_shillings DESC',
        _visitParams(range, personId: personId, extra: {
          if (domain != null) 'domain': domain,
          if (itemId != null) 'itemId': itemId,
        }),
      );
}
