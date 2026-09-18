import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/patients/beneficiary_context.dart';
import 'package:lifecare_api/modules/patients/patient_repository.dart';
import 'patient_analytics_repository.dart';

typedef _Range = ({String from, String to});

class PatientAnalyticsService {
  final PatientAnalyticsRepository _repo;
  final PatientRepository _patientRepo;

  PatientAnalyticsService(this._repo, this._patientRepo);

  /// Every method below is scoped to the CALLER's own corporate account —
  /// there is no corporateAccountId parameter anywhere in this service,
  /// deliberately, so a corporate portal session can never pull another
  /// account's figures by passing a different id.
  Future<void> _requireCorporateCaller(String callerPatientId) async {
    final row = await _patientRepo.findById(callerPatientId);
    if (row == null) throw ApiError.notFound('Patient not found');
    if (!isCorporatePrimaryRow(row)) {
      throw ApiError.forbidden('Analytics are only available to corporate accounts');
    }
  }

  _Range _resolveRange(String? from, String? to) => (
        from: from ?? _firstDayOfMonth(),
        to: to ?? _today(),
      );

  String _today() => DateTime.now().toIso8601String().substring(0, 10);

  String _firstDayOfMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
  }

  // ── Statistics helpers (Dart, not SQL — see patient_analytics_repository's
  // class doc for why) ───────────────────────────────────────────────────

  Map<String, double> _percentiles(List<double> sorted) {
    if (sorted.isEmpty) return {'p25': 0, 'p50': 0, 'p75': 0, 'p90': 0};
    double at(double p) {
      final idx = p * (sorted.length - 1);
      final lower = idx.floor();
      final upper = idx.ceil();
      if (lower == upper) return sorted[lower];
      final frac = idx - lower;
      return sorted[lower] + (sorted[upper] - sorted[lower]) * frac;
    }

    return {'p25': at(0.25), 'p50': at(0.5), 'p75': at(0.75), 'p90': at(0.9)};
  }

  List<Map<String, dynamic>> _histogram(List<double> values, {int buckets = 5}) {
    if (values.isEmpty) return [];
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    if (min == max) {
      return [
        {'bucket_from': min, 'bucket_to': max, 'count': values.length},
      ];
    }
    final width = (max - min) / buckets;
    final counts = List<int>.filled(buckets, 0);
    for (final v in values) {
      var idx = ((v - min) / width).floor();
      if (idx >= buckets) idx = buckets - 1;
      if (idx < 0) idx = 0;
      counts[idx]++;
    }
    return [
      for (var i = 0; i < buckets; i++)
        {
          'bucket_from': min + width * i,
          'bucket_to': min + width * (i + 1),
          'count': counts[i],
        },
    ];
  }

  // ── Financial ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getFinancial(
    String callerPatientId, {
    String? from,
    String? to,
  }) async {
    await _requireCorporateCaller(callerPatientId);
    final range = _resolveRange(from, to);
    final corpId = callerPatientId;

    final walletTotals = await _repo.getWalletTotals(corpId, from: range.from, to: range.to);
    final spendByBeneficiary = await _repo.getSpendByBeneficiary(corpId, from: range.from, to: range.to);
    final spendByServiceType = await _repo.getSpendByServiceType(corpId, from: range.from, to: range.to);
    final budget = await _repo.getAllocatedBudget(corpId);
    final currentBalance = await _repo.getCurrentBalance(corpId);

    final netSpend = (walletTotals['net_spend'] as num).toDouble();
    final totalDeposits = (walletTotals['total_deposits'] as num).toDouble();

    final costCentres = <String, Map<String, dynamic>>{};
    for (final row in spendByBeneficiary) {
      final ccId = row['cost_centre_id'] as String?;
      final key = ccId ?? 'unassigned';
      final entry = costCentres.putIfAbsent(
        key,
        () => {
          'cost_centre_id': ccId,
          'name': row['cost_centre_name'],
          'spend_shillings': 0.0,
          'encounter_count': 0,
        },
      );
      entry['spend_shillings'] =
          (entry['spend_shillings'] as double) + (row['spend_shillings'] as num).toDouble();
      entry['encounter_count'] =
          (entry['encounter_count'] as int) + (row['encounter_count'] as num).toInt();
    }

    final spends = spendByBeneficiary
        .map((r) => (r['spend_shillings'] as num).toDouble())
        .toList()
      ..sort();

    final days = DateTime.parse(range.to).difference(DateTime.parse(range.from)).inDays + 1;
    double? burnRatePerDay;
    String? projectedExhaustionDate;
    if (netSpend > 0 && days > 0) {
      burnRatePerDay = netSpend / days;
      if (currentBalance > 0) {
        final daysLeft = (currentBalance / burnRatePerDay).ceil();
        projectedExhaustionDate = DateTime.now()
            .toUtc()
            .add(Duration(days: daysLeft))
            .toIso8601String()
            .substring(0, 10);
      }
    }

    return {
      'period': {'from': range.from, 'to': range.to},
      'allocated_budget_shillings': budget,
      'total_spend_shillings': netSpend,
      'total_deposits_shillings': totalDeposits,
      'utilization_pct': (budget != null && budget > 0) ? (netSpend / budget * 100) : null,
      'cost_centre_breakdown': costCentres.values.toList(),
      'spend_per_beneficiary': {
        'percentiles': _percentiles(spends),
        'histogram': _histogram(spends),
      },
      'burn_rate': {
        'shillings_per_day': burnRatePerDay,
        'projected_exhaustion_date': projectedExhaustionDate,
      },
      'cost_by_visit_type': spendByServiceType
          .map((r) => {
                'service_type': r['service_type'],
                'spend_shillings': r['spend_shillings'],
                'count': r['count'],
              })
          .toList(),
    };
  }

  // ── Utilization ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getUtilization(
    String callerPatientId, {
    String? from,
    String? to,
  }) async {
    await _requireCorporateCaller(callerPatientId);
    final range = _resolveRange(from, to);
    final corpId = callerPatientId;

    final registered = await _repo.countRegisteredBeneficiaries(corpId);
    final active = await _repo.countActiveBeneficiaries(corpId, from: range.from, to: range.to);
    final visitCounts = await _repo.getVisitCountsByBeneficiary(corpId, from: range.from, to: range.to);
    // Already spend-ordered by the repository — doubles as "top service
    // types" here without a second query.
    final spendByServiceType = await _repo.getSpendByServiceType(corpId, from: range.from, to: range.to);
    final depVsPrimary = await _repo.getDependentVsPrimarySpend(corpId, from: range.from, to: range.to);

    final visitCountValues =
        visitCounts.map((r) => (r['visit_count'] as num).toDouble()).toList()..sort();

    final dependentSpend = (depVsPrimary['dependent_spend'] as num).toDouble();
    final primarySpend = (depVsPrimary['primary_spend'] as num).toDouble();

    return {
      'period': {'from': range.from, 'to': range.to},
      'registered_beneficiary_count': registered,
      'active_beneficiary_count': active,
      'take_up_rate_pct': registered > 0 ? (active / registered * 100) : 0,
      'visit_frequency_distribution': _histogram(visitCountValues),
      'top_service_types': spendByServiceType
          .take(10)
          .map((r) => {
                'service_type': r['service_type'],
                'visit_count': r['count'],
                'spend_shillings': r['spend_shillings'],
              })
          .toList(),
      'dependent_to_primary_spend_ratio': primarySpend > 0 ? (dependentSpend / primarySpend) : null,
    };
  }

  // ── Clinical (aggregate-only) ─────────────────────────────────────────

  /// Categories under this many encounters collapse into "other" — a
  /// small-cohort in a "top diagnosis category" bucket re-identifies
  /// someone even without a beneficiary id attached, so this is enforced
  /// here regardless of how small a corporate account's roster is.
  static const _minCohortSize = 5;

  Future<Map<String, dynamic>> getClinical(
    String callerPatientId, {
    String? from,
    String? to,
  }) async {
    await _requireCorporateCaller(callerPatientId);
    final range = _resolveRange(from, to);
    final corpId = callerPatientId;

    final rawBreakdown = await _repo.getDiagnosisCategoryBreakdown(corpId, from: range.from, to: range.to);
    final drugTrend = await _repo.getDrugDispensingTrend(corpId, from: range.from, to: range.to);

    final total = rawBreakdown.fold<int>(0, (sum, r) => sum + (r['count'] as num).toInt());

    var otherCount = 0;
    final kept = <Map<String, dynamic>>[];
    for (final row in rawBreakdown) {
      final count = (row['count'] as num).toInt();
      if (count < _minCohortSize) {
        otherCount += count;
      } else {
        kept.add(row);
      }
    }

    final breakdown = [
      for (final row in kept)
        {
          'category': row['category'],
          'pct': total > 0 ? (row['count'] as num).toDouble() / total * 100 : 0,
        },
      if (otherCount > 0)
        {'category': 'other', 'pct': total > 0 ? otherCount / total * 100 : 0},
    ];

    return {
      'period': {'from': range.from, 'to': range.to},
      'diagnosis_category_breakdown': breakdown,
      'drug_dispensing_trend': drugTrend,
    };
  }

  // ── Governance ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getGovernance(
    String callerPatientId, {
    String? from,
    String? to,
  }) async {
    await _requireCorporateCaller(callerPatientId);
    final range = _resolveRange(from, to);
    final corpId = callerPatientId;

    final actionCounts = await _repo.getAuditActionCounts(corpId, from: range.from, to: range.to);
    final accessCount = actionCounts.fold<int>(0, (sum, r) => sum + (r['count'] as num).toInt());

    final anomalies = await _detectAnomalies(corpId, range);

    final recon = await _repo.getWalletReconciliation(corpId);
    final balance = (recon['balance'] as num).toDouble();
    final ledgerSum = (recon['ledger_sum'] as num).toDouble();
    final discrepancy = balance - ledgerSum;

    return {
      'period': {'from': range.from, 'to': range.to},
      'audit_summary': {
        'access_count': accessCount,
        'by_action': actionCounts,
      },
      'anomaly_count': anomalies.length,
      'anomaly_list': anomalies,
      'wallet_reconciliation': {
        // Sub-shilling rounding noise, not a real discrepancy.
        'state': discrepancy.abs() < 1 ? 'reconciled' : 'discrepancy_flagged',
        'balance_shillings': balance,
        'ledger_sum_shillings': ledgerSum,
        'discrepancy_shillings': discrepancy,
      },
    };
  }

  /// First-pass, explicit anomaly rules — not a fraud engine. Likely to
  /// need a follow-up pass once this runs against real corporate-account
  /// data; see the plan doc for the full rationale.
  Future<List<Map<String, dynamic>>> _detectAnomalies(String corpId, _Range range) async {
    final anomalies = <Map<String, dynamic>>[];

    // Rule 1: 5+ failed logins for one identity within any 24h window.
    final failedLogins = await _repo.getFailedLoginEvents(corpId, from: range.from, to: range.to);
    final byUser = <String, List<DateTime>>{};
    for (final row in failedLogins) {
      final userId = row['user_id'] as String?;
      final ts = DateTime.tryParse(row['timestamp']?.toString() ?? '');
      if (userId == null || ts == null) continue;
      byUser.putIfAbsent(userId, () => []).add(ts);
    }
    for (final entry in byUser.entries) {
      final timestamps = entry.value..sort();
      for (var i = 0; i + (_failedLoginThreshold - 1) < timestamps.length; i++) {
        final windowEnd = timestamps[i + _failedLoginThreshold - 1];
        if (windowEnd.difference(timestamps[i]) <= const Duration(hours: 24)) {
          anomalies.add({
            'type': 'failed_login_spike',
            'patient_id': entry.key,
            'detected_at': windowEnd.toIso8601String(),
            'detail': '$_failedLoginThreshold+ failed login attempts within 24h',
          });
          break;
        }
      }
    }

    // Rules 2 & 3: off-hours or unreasoned balance adjustments.
    final adjustments = await _repo.getWalletAdjustments(corpId, from: range.from, to: range.to);
    for (final row in adjustments) {
      final createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
      if (createdAt == null) continue;
      final clinicHour =
          createdAt.toUtc().add(Duration(minutes: AppConfig.clinicTzOffsetMinutes)).hour;
      if (clinicHour < 6 || clinicHour >= 22) {
        anomalies.add({
          'type': 'off_hours_adjustment',
          'detected_at': createdAt.toIso8601String(),
          'detail': 'Balance adjustment outside 06:00-22:00 clinic time',
        });
      }
      final reason = (row['reason'] as String?)?.trim();
      if (reason == null || reason.isEmpty) {
        anomalies.add({
          'type': 'unreasoned_adjustment',
          'detected_at': createdAt.toIso8601String(),
          'detail': 'Balance adjustment with no reason recorded',
        });
      }
    }

    return anomalies;
  }

  static const _failedLoginThreshold = 5;
}
