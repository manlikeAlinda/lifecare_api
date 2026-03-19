import 'package:mysql_client/mysql_client.dart';

/// Converts a MySQL result row to a Dart map, coercing known types:
/// - tinyint(1) boolean columns (is_active, is_suspended, etc.) → bool
/// - int-like string columns (amount, balance, etc.) are left as strings
///   so callers can parse them as needed.
Map<String, dynamic> rowToMap(ResultSetRow row) {
  final map = Map<String, dynamic>.from(row.assoc());
  // Coerce every key ending in common boolean suffixes to bool
  const boolKeys = {
    'is_active', 'is_suspended', 'is_verified', 'is_primary',
    'is_default', 'is_deleted',
  };
  for (final key in boolKeys) {
    if (map.containsKey(key)) {
      final v = map[key];
      if (v is String) map[key] = v != '0';
      if (v is int) map[key] = v != 0;
    }
  }
  return map;
}
