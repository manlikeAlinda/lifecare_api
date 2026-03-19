import 'package:mysql_client/mysql_client.dart';
import 'package:lifecare_api/core/utils/row_map.dart';

class CatalogRepository {
  final MySQLConnectionPool _pool;

  CatalogRepository(this._pool);

  // ── DB column reality ─────────────────────────────────────────────────────
  // catalog_items:         catalog_item_id (PK), item_code, item_name,
  //                        item_type ('SERVICE'|'MEDICATION'|'LAB'|'PROCEDURE'),
  //                        is_lifecare_eligible, is_consultation, is_active,
  //                        created_at
  // catalog_price_versions: price_version_id (PK), catalog_item_id,
  //                         price_minor (bigint), active_from, created_by,
  //                         created_at, prev_price_version_id
  // drugs (legacy):        drug_id (INT PK), drug_name, drug_type, rate,
  //                        currency, is_active, created_at, updated_at
  // ─────────────────────────────────────────────────────────────────────────

  static const _uuidId =
      "LOWER(CONCAT(SUBSTR(HEX(ci.catalog_item_id),1,8),'-',"
      "SUBSTR(HEX(ci.catalog_item_id),9,4),'-',"
      "SUBSTR(HEX(ci.catalog_item_id),13,4),'-',"
      "SUBSTR(HEX(ci.catalog_item_id),17,4),'-',"
      "SUBSTR(HEX(ci.catalog_item_id),21))) AS id";

  // Latest active price for each item via correlated subquery.
  static const _priceJoin =
      'LEFT JOIN catalog_price_versions cpv '
      '  ON cpv.catalog_item_id = ci.catalog_item_id '
      '  AND cpv.active_from = ('
      '    SELECT MAX(active_from) FROM catalog_price_versions p2 '
      '    WHERE p2.catalog_item_id = ci.catalog_item_id '
      '    AND p2.active_from <= NOW()'
      '  )';

  static const _baseSelect =
      'SELECT $_uuidId, ci.item_code AS code, ci.item_name AS name, '
      'ci.item_type, ci.is_lifecare_eligible, ci.is_consultation, '
      'ci.is_active, ci.created_at, cpv.price_minor AS price '
      'FROM catalog_items ci $_priceJoin';

  Future<(List<Map<String, dynamic>>, int)> findServices({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
  }) async {
    return _findByTypes(
      ["'SERVICE'", "'LAB'", "'PROCEDURE'"],
      limit: limit,
      offset: offset,
      search: search,
    );
  }

  // ── Category-specific tables (production DB) ──────────────────────────────
  // Each category lives in its own table with slightly different columns.
  // We normalise to: id, name, category, rate, currency, is_active, created_at

  Future<(List<Map<String, dynamic>>, int)> findByCategory(
    String category, {
    int limit = 20,
    int offset = 0,
    String? search,
  }) async {
    switch (category.toLowerCase()) {
      case 'dental':
        return _queryCategory(
          table: 'dental_services',
          pkCol: 'dental_service_id',
          nameCol: 'procedure_name',
          categoryCol: 'category',
          extraCols: '',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'procedure_name',
        );
      case 'laboratory':
        return _queryCategory(
          table: 'lab_services',
          pkCol: 'lab_service_id',
          nameCol: 'service_name',
          categoryCol: 'category',
          extraCols: '',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'service_name',
        );
      case 'imaging':
        return _queryCategory(
          table: 'imaging_services',
          pkCol: 'imaging_service_id',
          nameCol: 'test_name',
          categoryCol: 'modality',
          extraCols: '',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'test_name',
        );
      case 'procedures':
        return _queryCategory(
          table: 'procedure_packages',
          pkCol: 'procedure_package_id',
          nameCol: 'procedure_name',
          categoryCol: 'category',
          extraCols: ', billing_unit',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'procedure_name',
        );
      case 'laparoscopic':
        return _queryCategory(
          table: 'laparoscopic_procedures',
          pkCol: 'laparoscopic_procedure_id',
          nameCol: 'procedure_name',
          categoryCol: 'category',
          extraCols: ', billing_unit',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'procedure_name',
        );
      case 'accommodation':
        return _queryCategory(
          table: 'accommodation_services',
          pkCol: 'accommodation_service_id',
          nameCol: 'service_name',
          categoryCol: 'category',
          extraCols: ', billing_unit',
          limit: limit,
          offset: offset,
          search: search,
          searchCol: 'service_name',
        );
      case 'consultation':
        return _queryConsultation(
          limit: limit,
          offset: offset,
          search: search,
        );
      default:
        return (<Map<String, dynamic>>[], 0);
    }
  }

  Future<(List<Map<String, dynamic>>, int)> _queryCategory({
    required String table,
    required String pkCol,
    required String nameCol,
    required String categoryCol,
    required String extraCols,
    required int limit,
    required int offset,
    String? search,
    String searchCol = 'name',
  }) async {
    final conditions = ['is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (search != null && search.isNotEmpty) {
      conditions.add('$searchCol LIKE :search');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM $table $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT $pkCol AS id, $nameCol AS name, $categoryCol AS category, '
      'rate, currency, is_active, created_at$extraCols '
      'FROM $table $where ORDER BY $nameCol LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<(List<Map<String, dynamic>>, int)> _queryConsultation({
    required int limit,
    required int offset,
    String? search,
  }) async {
    final conditions = ['is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (search != null && search.isNotEmpty) {
      conditions.add('department_name LIKE :search');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM consultation_fees $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT consultation_id AS id, department_name AS name, '
      'fee_type AS category, rate, currency, is_active, created_at '
      'FROM consultation_fees $where '
      'ORDER BY department_name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<(List<Map<String, dynamic>>, int)> findDrugs({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
  }) async {
    // drugs is a standalone legacy table — not linked to catalog_items.
    final conditions = ['is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (search != null && search.isNotEmpty) {
      conditions.add('drug_name LIKE :search');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM drugs $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      'SELECT drug_id AS id, drug_name AS name, drug_type, '
      'rate AS price, currency, is_active, created_at, updated_at '
      'FROM drugs $where ORDER BY drug_name LIMIT :limit OFFSET :offset',
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
      params['type'] = type.toUpperCase();
    }
    if (search != null && search.isNotEmpty) {
      conditions.add('(ci.item_name LIKE :search OR ci.item_code LIKE :search)');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM catalog_items ci $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_baseSelect $where '
      'ORDER BY ci.item_type, ci.item_name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<Map<String, dynamic>?> findById(String id) async {
    final result = await _pool.execute(
      '$_baseSelect '
      "WHERE ci.catalog_item_id = UNHEX(REPLACE(:id, '-', '')) LIMIT 1",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<(List<Map<String, dynamic>>, int)> _findByTypes(
    List<String> types, {
    required int limit,
    required int offset,
    String? search,
  }) async {
    final typeList = types.join(', ');
    final conditions = ['ci.item_type IN ($typeList)', 'ci.is_active = 1'];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (search != null && search.isNotEmpty) {
      conditions.add('(ci.item_name LIKE :search OR ci.item_code LIKE :search)');
      params['search'] = '%$search%';
    }

    final where = 'WHERE ${conditions.join(' AND ')}';

    final countResult = await _pool.execute(
      'SELECT COUNT(*) as total FROM catalog_items ci $where',
      params,
    );
    final total = int.parse(countResult.rows.first.assoc()['total'] ?? '0');

    final result = await _pool.execute(
      '$_baseSelect $where ORDER BY ci.item_name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Map<String, dynamic> _rowToMap(ResultSetRow row) => rowToMap(row);
}
