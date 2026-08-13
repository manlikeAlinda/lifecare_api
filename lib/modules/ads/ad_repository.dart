import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/audit/audit_writer.dart' as audit;
import 'package:lifecare_api/core/utils/row_map.dart';
import 'package:lifecare_api/core/utils/uuid.dart';

class AdRepository {
  final MySQLConnectionPool _pool;

  AdRepository(this._pool);

  String get _select => 'SELECT '
      '${uuidSelect('ad_id')}, title, body, cta_label, target_url, background_color, '
      'display_order, start_date, end_date, is_active, '
      '${uuidSelect('created_by')}, created_at, updated_at '
      'FROM ads';

  Future<(List<Map<String, dynamic>>, int)> findAllForAdmin({
    int limit = 20,
    int offset = 0,
    String? search,
  }) async {
    final where = StringBuffer('deleted_at IS NULL');
    final params = <String, dynamic>{'limit': limit, 'offset': offset};
    if (search != null && search.isNotEmpty) {
      where.write(' AND title LIKE :search');
      params['search'] = '%$search%';
    }

    final result = await _pool.execute(
      '$_select WHERE $where '
      'ORDER BY display_order ASC, created_at DESC '
      'LIMIT :limit OFFSET :offset',
      params,
    );

    final countResult = await _pool.execute(
      'SELECT COUNT(*) AS total FROM ads WHERE $where',
      params,
    );
    final total = (rowToMap(countResult.rows.first)['total'] as num).toInt();

    return (result.rows.map(rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      "$_select WHERE deleted_at IS NULL AND ${uuidWhere('ad_id', 'id')} LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return rowToMap(result.rows.first);
  }

  /// Ads visible to the mobile carousel: active, within date range, not
  /// deleted, ordered for display. No auth — this backs the public endpoint.
  Future<List<Map<String, dynamic>>> findActiveForPublic() async {
    final result = await _pool.execute(
      'SELECT ${uuidSelect('ad_id')}, title, body, cta_label, target_url, '
      'background_color, display_order '
      'FROM ads '
      'WHERE deleted_at IS NULL AND is_active = 1 '
      '  AND CURDATE() BETWEEN start_date AND end_date '
      'ORDER BY display_order ASC, created_at DESC',
      {},
    );
    return result.rows.map(rowToMap).toList();
  }

  Future<Map<String, dynamic>> create({
    required String adId,
    required String title,
    String? body,
    String? ctaLabel,
    String? targetUrl,
    String? backgroundColor,
    required int displayOrder,
    required String startDate,
    required String endDate,
    required bool isActive,
    required String createdBy,
  }) async {
    await _pool.transactional((conn) async {
      await conn.execute(
        'INSERT INTO ads '
        '(ad_id, title, body, cta_label, target_url, background_color, '
        ' display_order, start_date, end_date, is_active, created_by) '
        "VALUES (UNHEX(REPLACE(:adId, '-', '')), :title, :body, :ctaLabel, "
        ':targetUrl, :backgroundColor, :displayOrder, :startDate, :endDate, '
        ":isActive, UNHEX(REPLACE(:createdBy, '-', '')))",
        {
          'adId': adId,
          'title': title,
          'body': body,
          'ctaLabel': ctaLabel,
          'targetUrl': targetUrl,
          'backgroundColor': backgroundColor,
          'displayOrder': displayOrder,
          'startDate': startDate,
          'endDate': endDate,
          'isActive': isActive ? 1 : 0,
          'createdBy': createdBy,
        },
      );

      await audit.writeAudit(
        conn: conn,
        actorId: createdBy,
        action: 'create_ad',
        targetType: 'ad',
        targetIdUuid: adId,
        after: {'title': title, 'is_active': isActive},
      );
    });
    return (await findById(adId))!;
  }

  Future<Map<String, dynamic>?> update(
    String id,
    Map<String, dynamic> fields, {
    required String actorId,
  }) async {
    if (fields.isEmpty) return findById(id);

    final setClauses = fields.keys.map((k) => '$k = :$k').join(', ');
    final params = Map<String, dynamic>.from(fields)..['id'] = id;

    await _pool.transactional((conn) async {
      final before = await findById(id);

      await conn.execute(
        'UPDATE ads SET $setClauses '
        "WHERE deleted_at IS NULL AND ${uuidWhere('ad_id', 'id')}",
        params,
      );

      await audit.writeAudit(
        conn: conn,
        actorId: actorId,
        action: 'update_ad',
        targetType: 'ad',
        targetIdUuid: id,
        before: before,
        after: {...?before, ...fields},
      );
    });
    return findById(id);
  }

  Future<bool> softDelete(String id, {required String actorId}) async {
    var affected = 0;
    await _pool.transactional((conn) async {
      final result = await conn.execute(
        'UPDATE ads SET deleted_at = NOW(6) '
        "WHERE deleted_at IS NULL AND ${uuidWhere('ad_id', 'id')}",
        {'id': id},
      );
      affected = result.affectedRows.toInt();
      if (affected > 0) {
        await audit.writeAudit(
          conn: conn,
          actorId: actorId,
          action: 'archive_ad',
          targetType: 'ad',
          targetIdUuid: id,
        );
      }
    });
    return affected > 0;
  }

  Future<bool> hardDelete(String id, {required String actorId}) async {
    var affected = 0;
    await _pool.transactional((conn) async {
      final result = await conn.execute(
        "DELETE FROM ads WHERE ${uuidWhere('ad_id', 'id')}",
        {'id': id},
      );
      affected = result.affectedRows.toInt();
      if (affected > 0) {
        await audit.writeAudit(
          conn: conn,
          actorId: actorId,
          action: 'hard_delete_ad',
          targetType: 'ad',
          targetIdUuid: id,
        );
      }
    });
    return affected > 0;
  }
}
