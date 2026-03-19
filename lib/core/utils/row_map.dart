import 'package:mysql_client/mysql_client.dart';

/// Converts a MySQL result row to a Dart map, coercing known types:
/// - tinyint(1) boolean columns → bool
/// - decimal/int amount/quantity columns → num
Map<String, dynamic> rowToMap(ResultSetRow row) {
  final map = Map<String, dynamic>.from(row.assoc());

  const boolKeys = {
    'is_active', 'is_suspended', 'is_verified', 'is_primary',
    'is_default', 'is_deleted',
  };
  const numKeys = {
    'balance', 'amount', 'total_cost', 'price', 'unit_price',
    'total_price', 'rate', 'quantity', 'balance_shillings',
    'amount_shillings',
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
