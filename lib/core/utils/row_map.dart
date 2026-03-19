import 'package:mysql_client/mysql_client.dart';

/// Converts a MySQL result row to a Dart map with proper Dart types.
///
/// MySQL returns every value as a String. This helper coerces:
///   - tinyint(1) boolean columns        → bool
///   - int / decimal / aggregate columns  → num (int or double)
///
/// Add column names here whenever a new SELECT alias is introduced that
/// the app expects as a non-string type.
Map<String, dynamic> rowToMap(ResultSetRow row) {
  final map = Map<String, dynamic>.from(row.assoc());

  // ── Boolean columns (tinyint(1)) ──────────────────────────────────────────
  const boolKeys = {
    'is_active',
    'is_suspended',
    'is_verified',
    'is_primary',
    'is_default',
    'is_deleted',
    'is_lifecare_eligible',
    'is_consultation',
    'must_change_pw',
  };

  // ── Numeric columns (int, bigint, decimal, or computed aggregates) ─────────
  const numKeys = {
    // wallet
    'balance',
    'amount',
    'balance_shillings',
    'amount_shillings',
    // encounters / services / medications
    'total_cost',
    'price',
    'unit_price',
    'total_price',
    'rate',
    'quantity',
    // catalog
    'price_minor',
    // analytics aggregates
    'encounter_count',
    'total_billed',
    'total_revenue',
    'total_deposits',
    'count',
    'total',
    'val',
    // generic
    'new_patients',
    'active_patients',
    'open_encounters',
    'total_encounters',
  };

  for (final key in map.keys.toList()) {
    final v = map[key];
    if (v is! String) continue;
    if (boolKeys.contains(key)) {
      map[key] = v != '0';
    } else if (numKeys.contains(key)) {
      map[key] = num.tryParse(v) ?? v;
    }
  }

  return map;
}
