import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/encounters/encounter_repository.dart';
import 'package:lifecare_api/modules/wallets/wallet_repository.dart';
import 'patient_repository.dart';

/// Builds the chronological, running-balance account statement (Module 5)
/// shown to admins for a patient's whole wallet history — every visit
/// broken into its billed line items, every deposit/adjustment/etc. shown
/// as its own row, with a balance column carried across all of it.
///
/// v1 always starts from account inception (opening balance 0) — no
/// from/to range yet, so there is no carried-forward B/F to reconstruct.
class AccountStatementService {
  final WalletRepository _walletRepo;
  final EncounterRepository _encounterRepo;
  final PatientRepository _patientRepo;

  AccountStatementService(
    this._walletRepo,
    this._encounterRepo,
    this._patientRepo,
  );

  // Mirrors the sign convention actually applied by every ledger writer in
  // the system (WalletRepository.appendLedgerEntry for deposit/refund/
  // adjustment/opening_balance/deduction/debt_created, and
  // EncounterRepository's own hand-rolled SQL for deduction/reversal):
  // amount_shillings is stored as a positive magnitude for every type
  // except 'adjustment' (which is already signed), and the type alone
  // determines the running-balance direction.
  static const _creditTypes = {
    'deposit',
    'refund',
    'adjustment',
    'opening_balance',
    'reversal',
  };

  double _delta(Map<String, dynamic> entry) {
    final amount = (entry['amount_shillings'] as num).toDouble();
    final type = entry['type'] as String;
    return _creditTypes.contains(type) ? amount : -amount;
  }

  Future<Map<String, dynamic>> generate(String patientId) async {
    final patient = await _patientRepo.findById(patientId);
    if (patient == null) throw ApiError.notFound('Patient not found');

    final wallet = await _walletRepo.findByPatientId(patientId);
    if (wallet == null) {
      throw ApiError.notFound('Wallet not found for this patient');
    }

    final ledger = await _walletRepo.getAllLedgerForStatement(wallet['id'] as String);

    // Only the earliest ledger entry for a given encounter gets the full
    // line-item breakdown — a later entry against the same encounter (an
    // edit that changed the total, or its reversal) is shown as a single
    // summary row instead, since the encounter's *current* line items no
    // longer reflect what that specific delta was for.
    final firstLedgerIdByEncounter = <String, String>{};
    for (final entry in ledger) {
      final encId = entry['encounter_id'] as String?;
      if (encId == null) continue;
      firstLedgerIdByEncounter.putIfAbsent(encId, () => entry['id'] as String);
    }

    final encounterCache = <String, Map<String, dynamic>>{};
    for (final encId in firstLedgerIdByEncounter.keys) {
      final enc = await _encounterRepo.findById(encId);
      if (enc != null) encounterCache[encId] = enc;
    }

    final rows = <Map<String, dynamic>>[];
    double runningBalance = 0;
    const openingBalance = 0.0;

    for (final entry in ledger) {
      runningBalance += _delta(entry);
      final encId = entry['encounter_id'] as String?;

      if (encId != null &&
          entry['type'] == 'deduction' &&
          firstLedgerIdByEncounter[encId] == entry['id'] &&
          encounterCache.containsKey(encId)) {
        rows.addAll(_itemizedEncounterRows(encounterCache[encId]!, runningBalance));
      } else if (encId != null) {
        rows.add(_summaryEncounterRow(entry, encounterCache[encId], runningBalance));
      } else {
        rows.add(_summaryLedgerRow(entry, patient, runningBalance));
      }
    }

    return {
      'patient': {
        'id': patient['id'],
        'name': patient['full_name'],
        'code': patient['patient_code'],
      },
      'opening_balance': openingBalance,
      'closing_balance': runningBalance,
      'rows': rows,
    };
  }

  List<Map<String, dynamic>> _itemizedEncounterRows(
    Map<String, dynamic> encounter,
    double balanceAfter,
  ) {
    final name = (encounter['dependent_name'] as String?)?.isNotEmpty == true
        ? encounter['dependent_name'] as String
        : encounter['patient_name'] as String? ?? '';
    final date = encounter['visited_at'];
    final services = (encounter['services'] as List).cast<Map<String, dynamic>>();
    final medications = (encounter['medications'] as List).cast<Map<String, dynamic>>();
    final discount = (encounter['discount_shillings'] as num?)?.toDouble() ?? 0;

    final lines = <Map<String, dynamic>>[
      for (final s in services)
        {'narrative': s['name'], 'amount': (s['total_price'] as num).toDouble()},
      for (final m in medications)
        {'narrative': m['name'], 'amount': (m['total_price'] as num).toDouble()},
      if (discount > 0) {'narrative': 'Discount', 'amount': -discount},
    ];
    if (lines.isEmpty) {
      // No stored line items (shouldn't happen — every encounter requires
      // at least one — but never emit a group with zero rows).
      lines.add({'narrative': encounter['service_type'] ?? 'Visit', 'amount': 0.0});
    }

    return [
      for (var i = 0; i < lines.length; i++)
        {
          'date': i == 0 ? date : null,
          'name': i == 0 ? name : null,
          'narrative': lines[i]['narrative'],
          'amount': lines[i]['amount'],
          'total': i == lines.length - 1
              ? (encounter['total_cost'] as num).toDouble()
              : null,
          'balance': i == lines.length - 1 ? balanceAfter : null,
          'is_credit': false,
        },
    ];
  }

  Map<String, dynamic> _summaryEncounterRow(
    Map<String, dynamic> entry,
    Map<String, dynamic>? encounter,
    double balanceAfter,
  ) {
    final name = encounter == null
        ? ''
        : (encounter['dependent_name'] as String?)?.isNotEmpty == true
            ? encounter['dependent_name'] as String
            : encounter['patient_name'] as String? ?? '';
    final ref = entry['encounter_reference'] as String? ?? '';
    final label = entry['type'] == 'reversal' ? 'Visit Reversal' : 'Visit Adjustment';
    final amount = (entry['amount_shillings'] as num).toDouble();
    return {
      'date': entry['created_at'],
      'name': name,
      'narrative': ref.isNotEmpty ? '$label (Ref: $ref)' : label,
      'amount': amount.abs(),
      'total': amount.abs(),
      'balance': balanceAfter,
      'is_credit': entry['type'] == 'reversal',
    };
  }

  Map<String, dynamic> _summaryLedgerRow(
    Map<String, dynamic> entry,
    Map<String, dynamic> patient,
    double balanceAfter,
  ) {
    final type = entry['type'] as String;
    final reason = entry['reason'] as String?;
    final amount = (entry['amount_shillings'] as num).toDouble();

    String narrative;
    switch (type) {
      case 'deposit':
        narrative = 'LCA Deposit';
        break;
      case 'refund':
        narrative = reason?.isNotEmpty == true ? 'Refund: $reason' : 'Refund';
        break;
      case 'opening_balance':
        narrative = 'Opening Balance';
        break;
      case 'debt_created':
        narrative = reason?.isNotEmpty == true ? 'Debt Created: $reason' : 'Debt Created';
        break;
      case 'adjustment':
        final direction = amount < 0 ? ' (decrease)' : '';
        narrative = 'Balance Adjustment$direction'
            '${reason?.isNotEmpty == true ? ': $reason' : ''}';
        break;
      case 'reversal':
        narrative = reason?.isNotEmpty == true ? 'Reversal: $reason' : 'Reversal';
        break;
      default:
        narrative = type;
    }

    // 'adjustment' is bidirectional — amount_shillings carries the real
    // sign (see WalletRepository.appendLedgerEntry), so is_credit must
    // reflect that sign rather than the blanket per-type membership below
    // (which would otherwise mark a decrease adjustment as a credit).
    final isCredit = type == 'adjustment' ? amount >= 0 : _creditTypes.contains(type);

    return {
      'date': entry['created_at'],
      'name': patient['full_name'],
      'narrative': narrative,
      'amount': amount.abs(),
      'total': amount.abs(),
      'balance': balanceAfter,
      'is_credit': isCredit,
    };
  }
}
