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

  // action_type, entity_type, request_id are legacy columns from an earlier
  // schema revision — still NOT NULL with no default on the real table
  // (unlike db/schema.sql, which doesn't have them at all). Omitting them
  // throws under strict mode, silently rolling back whatever transaction
  // this write is part of. action/target_type duplicate into action_type/
  // entity_type rather than leaving them blank; request_id has no value
  // available this deep in the call stack, so it's left empty — matches
  // the convention already present in existing rows.
  await conn.execute(
    'INSERT INTO audit_log '
    '(audit_id, user_id, actor_user_id, action_type, entity_type, request_id, '
    ' action, target_type, target_id, details) '
    "VALUES (UNHEX(REPLACE(:auditId, '-', '')), UNHEX(REPLACE(:actorId, '-', '')), "
    "UNHEX(REPLACE(:actorId, '-', '')), "
    ':action, :targetType, \'\', '
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
