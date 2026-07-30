import 'dart:convert';

import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

/// Writes an audit_log row on the same connection/transaction as the
/// mutation it records, so the two can never diverge (no more "the write
/// succeeded but the audit didn't" or vice versa).
///
/// [targetIdUuid] populates the audit_log.target_id column (BINARY(16)) for
/// UUID-keyed entities (patients, encounters, users, wallets). Entities with
/// a non-UUID primary key (catalog services/drugs use INT) pass their id via
/// [entityId] instead, which is embedded in details only — target_id stays
/// NULL since the column can't hold it.
///
/// [before]/[after] are full row snapshots, JSON-encoded — not diffed, so
/// every call site stays simple and consistent.
Future<void> writeAudit({
  required MySQLConnection conn,
  required String actorId,
  required String action,
  required String targetType,
  String? targetIdUuid,
  Object? entityId,
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
}) async {
  final details = jsonEncode({
    if (entityId != null) 'entity_id': entityId,
    if (before != null) 'before': before,
    if (after != null) 'after': after,
  });

  await conn.execute(
    'INSERT INTO audit_log '
    '(audit_id, user_id, action, target_type, target_id, details) '
    "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:actorId, '-', '')), "
    ':action, :targetType, '
    "${targetIdUuid != null ? "UNHEX(REPLACE(:targetIdUuid, '-', ''))" : 'NULL'}, "
    ':details)',
    {
      'auditId': generateUuid(),
      'actorId': actorId,
      'action': action,
      'targetType': targetType,
      if (targetIdUuid != null) 'targetIdUuid': targetIdUuid,
      'details': details,
    },
  );
}
