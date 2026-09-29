import 'package:lifecare_api/core/utils/clinic_time.dart';
import 'package:lifecare_api/modules/patients/account_statement_service.dart';
import 'report_logic.dart';
import 'reports_repository.dart';

/// Shapes the /v1/reports/* responses. Every list response is
/// `{rows, total, limit, offset, totals…}` — `total` is the size of the full
/// filtered set, and the aggregate fields always cover the full set, never
/// just the returned page.
class ReportsService {
  final ReportsRepository _repo;
  final AccountStatementService _statements;

  ReportsService(this._repo, this._statements);

  static DateTime? _time(String? raw) => raw == null || raw.isEmpty
      ? null
      : DateTime.parse('${raw.replaceFirst(' ', 'T')}Z');

  static String? _iso(DateTime? t) => t?.toIso8601String();

  static num _num(String? raw) => num.tryParse(raw ?? '') ?? 0;

  static List<T> _page<T>(List<T> all, int limit, int offset) =>
      all.skip(offset).take(limit).toList();

  // ── 1. Debtors ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> debtors({
    int? minOwed,
    ClinicDateRange? owingRange,
    required int limit,
    required int offset,
  }) async {
    final wallets = await _repo.debtorWallets();
    final ledger = await _repo.debtorLedger();

    final movementsByWallet = <String, List<LedgerMovement>>{};
    for (final r in ledger) {
      movementsByWallet.putIfAbsent(r['wallet_id']!, () => []).add(
            LedgerMovement(
              type: r['type'] ?? '',
              amount: _num(r['amount_shillings']).toInt(),
              at: _time(r['created_at'])!,
            ),
          );
    }

    final rows = <Map<String, dynamic>>[];
    for (final w in wallets) {
      final owed = _num(w['owed_shillings']).toInt();
      if (minOwed != null && owed < minOwed) continue;
      final summary = debtSummary(movementsByWallet[w['wallet_id']] ?? const []);
      final since = summary.owingSince;
      if (owingRange != null &&
          (since == null ||
              since.isBefore(owingRange.fromUtc) ||
              !since.isBefore(owingRange.toUtc))) {
        continue;
      }
      rows.add({
        'patient_id': w['patient_id'],
        'patient_code': w['patient_code'],
        'full_name': w['full_name'],
        'phone': w['phone_e164'],
        'owed_shillings': owed,
        'owing_since': _iso(since),
        'last_payment_at': _iso(summary.lastPaymentAt),
      });
    }
    rows.sort((a, b) => (b['owed_shillings'] as int).compareTo(a['owed_shillings'] as int));

    return {
      'rows': _page(rows, limit, offset),
      'total': rows.length,
      'limit': limit,
      'offset': offset,
      'total_owed_shillings':
          rows.fold<int>(0, (s, r) => s + (r['owed_shillings'] as int)),
    };
  }

  // ── 2. Deposits ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> deposits({
    required ClinicDateRange range,
    int? minAmount,
    String? method,
    String? personId,
    required int limit,
    required int offset,
  }) async {
    final rows = await _repo.deposits(
      range: range,
      minAmount: minAmount ?? 0,
      method: method,
      personId: personId,
      limit: limit,
      offset: offset,
    );
    final byMethod = await _repo.depositTotalsByMethod(
      range: range,
      minAmount: minAmount ?? 0,
      method: method,
      personId: personId,
    );
    final breakdown = [
      for (final m in byMethod)
        {
          'method': m['method'],
          'count': _num(m['count']).toInt(),
          'total_shillings': _num(m['total_shillings']).toInt(),
        },
    ];
    return {
      'rows': [
        for (final r in rows)
          {
            'transaction_id': r['transaction_id'],
            'patient_code': r['patient_code'],
            'full_name': r['full_name'],
            'amount_shillings': _num(r['amount_shillings']).toInt(),
            'method': r['method'],
            'processed_by': r['processed_by'],
            'created_at': _iso(_time(r['created_at'])),
          },
      ],
      'total': breakdown.fold<int>(0, (s, m) => s + (m['count'] as int)),
      'limit': limit,
      'offset': offset,
      'total_shillings':
          breakdown.fold<int>(0, (s, m) => s + (m['total_shillings'] as int)),
      'by_method': breakdown,
    };
  }

  // ── 3. New accounts ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> newAccounts({
    required ClinicDateRange range,
    required int limit,
    required int offset,
  }) async {
    final all = await _repo.newAccounts(range);
    final byMonth = <String, Map<String, dynamic>>{};
    final rows = <Map<String, dynamic>>[];
    for (final r in all) {
      final createdAt = _time(r['created_at'])!;
      final isBeneficiary = r['account_type'] == 'dependent';
      final day = ClinicTime.clinicDateOf(createdAt);
      final month = '${day.year}-${day.month.toString().padLeft(2, '0')}';
      final bucket = byMonth.putIfAbsent(
          month, () => {'month': month, 'primary': 0, 'beneficiary': 0, 'total': 0});
      bucket[isBeneficiary ? 'beneficiary' : 'primary'] += 1;
      bucket['total'] += 1;
      rows.add({
        'patient_id': r['patient_id'],
        'patient_code': r['patient_code'],
        'full_name': r['full_name'],
        'account_type': r['account_type'],
        'role': isBeneficiary ? 'beneficiary' : 'primary',
        'primary_name': r['primary_name'],
        'registered_by': r['registered_by'],
        'created_at': _iso(createdAt),
      });
    }
    return {
      'rows': _page(rows, limit, offset),
      'total': rows.length,
      'limit': limit,
      'offset': offset,
      'by_month': byMonth.values.toList()
        ..sort((a, b) => (a['month'] as String).compareTo(b['month'] as String)),
    };
  }

  // ── 4. Inactive accounts ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> inactiveAccounts({
    required int months,
    required int limit,
    required int offset,
  }) async {
    final now = ClinicTime.nowUtc();
    final cutoff = inactivityCutoff(now, months);
    final rows = <Map<String, dynamic>>[];
    for (final r in await _repo.accountActivity()) {
      final last = latestActivity([
        _time(r['last_visit_at']),
        _time(r['last_transaction_at']),
        _time(r['last_login_at']),
      ]);
      // Never used: measure inactivity from when the account was opened.
      final since = last ?? _time(r['created_at'])!;
      if (!since.isBefore(cutoff)) continue;
      rows.add({
        'patient_id': r['patient_id'],
        'patient_code': r['patient_code'],
        'full_name': r['full_name'],
        'phone': r['phone_e164'],
        'account_type': r['account_type'],
        'last_activity_at': _iso(last),
        'days_inactive': now.difference(since).inDays,
        'status': r['is_active'] == '1' ? 'active' : 'deactivated',
        'never_used': last == null,
      });
    }
    rows.sort((a, b) => (b['days_inactive'] as int).compareTo(a['days_inactive'] as int));
    return {
      'rows': _page(rows, limit, offset),
      'total': rows.length,
      'limit': limit,
      'offset': offset,
      'months': months,
      'cutoff': _iso(cutoff),
    };
  }

  // ── 5. Individual account ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> account(String patientId, ClinicDateRange range) =>
      _statements.generate(patientId, fromUtc: range.fromUtc, toUtc: range.toUtc);

  // ── 6. Drugs ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> drugs({
    required ClinicDateRange range,
    int? drugId,
    String? personId,
    required int limit,
    required int offset,
  }) async {
    final lines = await _repo.drugLines(
        range: range, drugId: drugId, personId: personId, limit: limit, offset: offset);
    final totals = await _repo.drugTotals(range: range, drugId: drugId, personId: personId);
    final byDrug = [
      for (final t in totals)
        {
          'drug_id': _num(t['drug_id']).toInt(),
          'name': t['medication_name'],
          'line_count': _num(t['line_count']).toInt(),
          'quantity': _num(t['quantity']).toInt(),
          'total_shillings': _num(t['total_shillings']).round(),
        },
    ];
    return {
      'rows': [for (final l in lines) _visitLine(l, name: l['medication_name'], price: l['rate'])],
      'total': byDrug.fold<int>(0, (s, d) => s + (d['line_count'] as int)),
      'limit': limit,
      'offset': offset,
      'total_shillings': byDrug.fold<int>(0, (s, d) => s + (d['total_shillings'] as int)),
      'by_drug': byDrug,
    };
  }

  // ── 7. Services ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> services({
    required ClinicDateRange range,
    String? domain,
    int? itemId,
    String? personId,
    required int limit,
    required int offset,
  }) async {
    final lines = await _repo.serviceLines(
        range: range, domain: domain, itemId: itemId, personId: personId,
        limit: limit, offset: offset);
    final totals = await _repo.serviceTotals(
        range: range, domain: domain, itemId: itemId, personId: personId);
    final byService = [
      for (final t in totals)
        {
          'domain': t['domain'],
          'name': t['service_name'],
          'line_count': _num(t['line_count']).toInt(),
          'total_shillings': _num(t['total_shillings']).round(),
        },
    ];
    return {
      'rows': [
        for (final l in lines)
          {..._visitLine(l, name: l['service_name'], price: l['price']), 'domain': l['domain']},
      ],
      'total': byService.fold<int>(0, (s, d) => s + (d['line_count'] as int)),
      'limit': limit,
      'offset': offset,
      'total_shillings': byService.fold<int>(0, (s, d) => s + (d['total_shillings'] as int)),
      'by_service': byService,
    };
  }

  Map<String, dynamic> _visitLine(
    Map<String, String?> l, {
    required String? name,
    required String? price,
  }) =>
      {
        'visited_at': _iso(_time(l['visited_at'])),
        'reference': l['reference_number'],
        'patient_code': l['patient_code'],
        'account_name': l['account_name'],
        'beneficiary_name': l['beneficiary_name'],
        'name': name,
        'quantity': _num(l['quantity']).toInt(),
        'unit_price_shillings': _num(price).round(),
        'line_total_shillings': _num(l['line_total']).round(),
      };
}
