import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String generateUuid() => _uuid.v4();

/// Converts a UUID string to a hex string suitable for BINARY(16) MySQL storage.
/// Input:  '550e8400-e29b-41d4-a716-446655440000'
/// Output: '550E8400E29B41D4A716446655440000'
String uuidToHex(String uuid) => uuid.replaceAll('-', '').toUpperCase();

/// Converts a raw HEX string from MySQL HEX(col) back to a UUID string.
/// Input:  '550E8400E29B41D4A716446655440000'
/// Output: '550e8400-e29b-41d4-a716-446655440000'
String hexToUuid(String hex) {
  final h = hex.toLowerCase();
  return '${h.substring(0, 8)}-'
      '${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-'
      '${h.substring(20)}';
}

/// SQL expression: reads a BINARY(16) column as a UUID string.
String uuidSelect(String column, [String? alias]) =>
    'LOWER(CONCAT('
    'SUBSTR(HEX($column),1,8),\'-\','
    'SUBSTR(HEX($column),9,4),\'-\','
    'SUBSTR(HEX($column),13,4),\'-\','
    'SUBSTR(HEX($column),17,4),\'-\','
    'SUBSTR(HEX($column),21)'
    ')) AS ${alias ?? column}';

/// SQL expression: compares a BINARY(16) column against a UUID string param.
/// Example: uuidWhere('id', 'id') → "id = UNHEX(REPLACE(:id, '-', ''))"
String uuidWhere(String column, String paramName) =>
    "$column = UNHEX(REPLACE(:$paramName, '-', ''))";

/// SQL expression: converts a UUID string param to BINARY(16) for INSERT/UPDATE.
String uuidParam(String paramName) =>
    "UNHEX(REPLACE(:$paramName, '-', ''))";
