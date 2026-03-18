import 'package:mysql_client/mysql_client.dart';

class CatalogRepository {
  final MySQLConnectionPool _pool;

  CatalogRepository(this._pool);

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(ci.id),1,8),'-',SUBSTR(HEX(ci.id),9,4),'-',SUBSTR(HEX(ci.id),13,4),'-',SUBSTR(HEX(ci.id),17,4),'-',SUBSTR(HEX(ci.id),21))) AS id";

  static const _baseSelect =
      'SELECT $_uuidId, ci.code, ci.name, ci.category, ci.unit, ci.price, '
      'ci.item_type, ci.description, ci.is_active, ci.created_at, ci.updated_at '
      'FROM catalog_items ci';

  Future<(List<Map<String, dynamic>>, int)> findServices({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
  }) async {
    return _findByType('service', limit: limit, offset: offset, category: category, search: search);
  }

  Future<(List<Map<String, dynamic>>, int)> findDrugs({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
  }) async {
    final conditions = ['ci.item_type = \'drug\'', 'ci.is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (category != null) {
      conditions.add('ci.category = :category');
      params['category'] = category;
    }
    if (search != null && search.isNotEmpty) {
      conditions.add('(ci.name LIKE :search OR ci.code LIKE :search OR d.generic_name LIKE :search OR d.brand_name LIKE :search)');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM catalog_items ci '
      'LEFT JOIN drugs d ON ci.id = d.catalog_item_id $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT $_uuidId, ci.code, ci.name, ci.category, ci.unit, ci.price, '
      'ci.item_type, ci.description, ci.is_active, ci.created_at, ci.updated_at, '
      'd.generic_name, d.brand_name, d.dosage_form, d.strength '
      'FROM catalog_items ci '
      'LEFT JOIN drugs d ON ci.id = d.catalog_item_id '
      '$where ORDER BY ci.name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<(List<Map<String, dynamic>>, int)> findAll({
    int limit = 20,
    int offset = 0,
    String? type,
    String? category,
    String? search,
  }) async {
    final conditions = ['ci.is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (type != null) {
      conditions.add('ci.item_type = :type');
      params['type'] = type;
    }
    if (category != null) {
      conditions.add('ci.category = :category');
      params['category'] = category;
    }
    if (search != null && search.isNotEmpty) {
      conditions.add('(ci.name LIKE :search OR ci.code LIKE :search)');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM catalog_items ci $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_baseSelect $where ORDER BY ci.item_type, ci.category, ci.name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      'SELECT $_uuidId, ci.code, ci.name, ci.category, ci.unit, ci.price, '
      'ci.item_type, ci.description, ci.is_active, ci.created_at, ci.updated_at, '
      'd.generic_name, d.brand_name, d.dosage_form, d.strength '
      'FROM catalog_items ci '
      'LEFT JOIN drugs d ON ci.id = d.catalog_item_id '
      "WHERE ci.id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<(List<Map<String, dynamic>>, int)> _findByType(
    String type, {
    required int limit,
    required int offset,
    String? category,
    String? search,
  }) async {
    final conditions = ["ci.item_type = '$type'", 'ci.is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (category != null) {
      conditions.add('ci.category = :category');
      params['category'] = category;
    }
    if (search != null && search.isNotEmpty) {
      conditions.add('(ci.name LIKE :search OR ci.code LIKE :search)');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM catalog_items ci $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_baseSelect $where ORDER BY ci.category, ci.name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) =>
      Map<String, dynamic>.from(row.assoc());
}
