import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

/// General, filterable audit-log reads — distinct from
/// UserRepository.getAuditLog, which is scoped to a single staff user.
/// Backs the desktop admin audit-log viewer.
class AuditRepository {
  final MySQLConnectionPool _pool;

  AuditRepository(this._pool);

  Future<(List<Map<String, dynamic>>, int)> list({
    int limit = 20,
    int offset = 0,
    String? beneficiaryId,
    String? actorId,
    String? action,
  }) async {
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (beneficiaryId != null && beneficiaryId.isNotEmpty) {
      conditions.add(uuidWhere('al.target_id', 'beneficiaryId'));
      params['beneficiaryId'] = beneficiaryId;
    }
    if (actorId != null && actorId.isNotEmpty) {
      conditions.add(uuidWhere('al.user_id', 'actorId'));
      params['actorId'] = actorId;
    }
    if (action != null && action.isNotEmpty) {
      conditions.add('al.action LIKE :action');
      params['action'] = '%$action%';
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final countParams = Map<String, dynamic>.from(params)
      ..remove('limit')
      ..remove('offset');
    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM audit_log al $where',
      countParams,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    // Actor may be a staff user (users table) OR a patient acting on their
    // own behalf (self-service audit entries, e.g. a primary requesting
    // login access for a beneficiary) — try both, staff wins if somehow
    // both match, 'System' if neither.
    final result = await _pool.execute(
      'SELECT '
      '${uuidSelect('al.audit_id', 'id')}, '
      'al.action, al.target_type, '
      '${uuidSelect('al.target_id', 'target_id')}, '
      'al.timestamp, al.details, '
      "COALESCE(u.display_name, u.username, p_actor.full_name, 'System') AS actor, "
      'target.full_name AS target_name '
      'FROM audit_log al '
      'LEFT JOIN users u ON u.user_id = al.user_id '
      'LEFT JOIN patients p_actor ON p_actor.patient_id = al.user_id '
      'LEFT JOIN patients target ON target.patient_id = al.target_id '
      '$where '
      'ORDER BY al.timestamp DESC LIMIT :limit OFFSET :offset',
      params,
    );

    return (
      result.rows.map((r) => Map<String, dynamic>.from(r.assoc())).toList(),
      total,
    );
  }
}
