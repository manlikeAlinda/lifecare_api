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
  // Normalised response: id (int), name, category, rate, billing_unit, notes
  // Tables without billing_unit/notes return NULL for those fields.

  // ── Domain config lookup ──────────────────────────────────────────────────
  // Maps slug → table metadata. Returns null for unknown slugs.
  ({
    String table,
    String pkCol,
    String nameCol,
    String categoryCol,
    String? billingUnitCol,
    String? notesCol,
  })? _domainConfig(String domain) {
    switch (domain.toLowerCase()) {
      case 'dental':
        return (table: 'dental_services', pkCol: 'dental_service_id', nameCol: 'procedure_name', categoryCol: 'category', billingUnitCol: null, notesCol: null);
      case 'lab':
      case 'laboratory':
        return (table: 'lab_services', pkCol: 'lab_service_id', nameCol: 'service_name', categoryCol: 'category', billingUnitCol: null, notesCol: null);
      case 'imaging':
        return (table: 'imaging_services', pkCol: 'imaging_service_id', nameCol: 'test_name', categoryCol: 'modality', billingUnitCol: null, notesCol: null);
      case 'procedures':
        return (table: 'procedure_packages', pkCol: 'procedure_package_id', nameCol: 'procedure_name', categoryCol: 'category', billingUnitCol: 'billing_unit', notesCol: 'notes');
      case 'laparoscopic':
        return (table: 'laparoscopic_procedures', pkCol: 'laparoscopic_procedure_id', nameCol: 'procedure_name', categoryCol: 'category', billingUnitCol: 'billing_unit', notesCol: 'notes');
      case 'accommodation':
        return (table: 'accommodation_services', pkCol: 'accommodation_service_id', nameCol: 'service_name', categoryCol: 'category', billingUnitCol: 'billing_unit', notesCol: 'notes');
      case 'consultation':
        return (table: 'consultation_fees', pkCol: 'consultation_id', nameCol: 'department_name', categoryCol: 'fee_type', billingUnitCol: null, notesCol: null);
      default:
        return null;
    }
  }

  // ── Category CRUD ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> findByDomainAndId(String domain, int id) async {
    final cfg = _domainConfig(domain);
    if (cfg == null) return null;
    final billingExpr = cfg.billingUnitCol ?? 'NULL AS billing_unit';
    final notesExpr = cfg.notesCol ?? 'NULL AS notes';
    final result = await _pool.execute(
      'SELECT ${cfg.pkCol} AS id, ${cfg.nameCol} AS name, '
      '${cfg.categoryCol} AS category, rate, $billingExpr, $notesExpr '
      'FROM ${cfg.table} WHERE ${cfg.pkCol} = :id LIMIT 1',
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return _rowToMap(result.rows.first);
  }

  Future<Map<String, dynamic>?> createByDomain(
    String domain,
    Map<String, dynamic> data,
  ) async {
    final cfg = _domainConfig(domain);
    if (cfg == null) return null;

    final cols = <String>[cfg.nameCol, cfg.categoryCol, 'rate', 'is_active'];
    final vals = <String>[':name', ':category', ':rate', '1'];
    final params = <String, dynamic>{
      'name': data['name'],
      'category': data['category'] ?? '',
      'rate': data['rate'] ?? 0,
    };

    if (cfg.billingUnitCol != null) {
      cols.add(cfg.billingUnitCol!);
      vals.add(':billing_unit');
      params['billing_unit'] = data['billing_unit'];
    }
    if (cfg.notesCol != null) {
      cols.add(cfg.notesCol!);
      vals.add(':notes');
      params['notes'] = data['notes'];
    }

    final result = await _pool.execute(
      'INSERT INTO ${cfg.table} (${cols.join(', ')}) VALUES (${vals.join(', ')})',
      params,
    );
    return findByDomainAndId(domain, result.lastInsertID.toInt());
  }

  Future<Map<String, dynamic>?> updateByDomain(
    String domain,
    int id,
    Map<String, dynamic> data,
  ) async {
    final cfg = _domainConfig(domain);
    if (cfg == null) return null;

    final setClauses = <String>[];
    final params = <String, dynamic>{'id': id};

    if (data.containsKey('name')) {
      setClauses.add('${cfg.nameCol} = :name');
      params['name'] = data['name'];
    }
    if (data.containsKey('category')) {
      setClauses.add('${cfg.categoryCol} = :category');
      params['category'] = data['category'];
    }
    if (data.containsKey('rate')) {
      setClauses.add('rate = :rate');
      params['rate'] = data['rate'];
    }
    if (cfg.billingUnitCol != null && data.containsKey('billing_unit')) {
      setClauses.add('${cfg.billingUnitCol} = :billing_unit');
      params['billing_unit'] = data['billing_unit'];
    }
    if (cfg.notesCol != null && data.containsKey('notes')) {
      setClauses.add('${cfg.notesCol} = :notes');
      params['notes'] = data['notes'];
    }

    if (setClauses.isNotEmpty) {
      await _pool.execute(
        'UPDATE ${cfg.table} SET ${setClauses.join(', ')} WHERE ${cfg.pkCol} = :id',
        params,
      );
    }
    return findByDomainAndId(domain, id);
  }

  Future<bool> deleteByDomain(String domain, int id) async {
    final cfg = _domainConfig(domain);
    if (cfg == null) return false;
    final result = await _pool.execute(
      'DELETE FROM ${cfg.table} WHERE ${cfg.pkCol} = :id',
      {'id': id},
    );
    return result.affectedRows.toInt() > 0;
  }

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
          billingUnitCol: null,   // table has no billing_unit
          notesCol: null,
          searchCol: 'procedure_name',
          limit: limit, offset: offset, search: search,
        );
      case 'lab':
      case 'laboratory':
        return _queryCategory(
          table: 'lab_services',
          pkCol: 'lab_service_id',
          nameCol: 'service_name',
          categoryCol: 'category',
          billingUnitCol: null,
          notesCol: null,
          searchCol: 'service_name',
          limit: limit, offset: offset, search: search,
        );
      case 'imaging':
        return _queryCategory(
          table: 'imaging_services',
          pkCol: 'imaging_service_id',
          nameCol: 'test_name',
          categoryCol: 'modality',
          billingUnitCol: null,
          notesCol: null,
          searchCol: 'test_name',
          limit: limit, offset: offset, search: search,
        );
      case 'procedures':
        return _queryCategory(
          table: 'procedure_packages',
          pkCol: 'procedure_package_id',
          nameCol: 'procedure_name',
          categoryCol: 'category',
          billingUnitCol: 'billing_unit',
          notesCol: 'notes',
          searchCol: 'procedure_name',
          limit: limit, offset: offset, search: search,
        );
      case 'laparoscopic':
        return _queryCategory(
          table: 'laparoscopic_procedures',
          pkCol: 'laparoscopic_procedure_id',
          nameCol: 'procedure_name',
          categoryCol: 'category',
          billingUnitCol: 'billing_unit',
          notesCol: 'notes',
          searchCol: 'procedure_name',
          limit: limit, offset: offset, search: search,
        );
      case 'accommodation':
        return _queryCategory(
          table: 'accommodation_services',
          pkCol: 'accommodation_service_id',
          nameCol: 'service_name',
          categoryCol: 'category',
          billingUnitCol: 'billing_unit',
          notesCol: 'notes',
          searchCol: 'service_name',
          limit: limit, offset: offset, search: search,
        );
      case 'consultation':
        return _queryConsultation(limit: limit, offset: offset, search: search);
      default:
        return (<Map<String, dynamic>>[], 0);
    }
  }

  Future<(List<Map<String, dynamic>>, int)> _queryCategory({
    required String table,
    required String pkCol,
    required String nameCol,
    required String categoryCol,
    required String? billingUnitCol,
    required String? notesCol,
    required String searchCol,
    required int limit,
    required int offset,
    String? search,
  }) async {
    final billingUnitExpr =
        billingUnitCol != null ? billingUnitCol : 'NULL AS billing_unit';
    final notesExpr = notesCol != null ? notesCol : 'NULL AS notes';

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
      'rate, $billingUnitExpr, $notesExpr '
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
      'fee_type AS category, rate, NULL AS billing_unit, NULL AS notes '
      'FROM consultation_fees $where '
      'ORDER BY department_name LIMIT :limit OFFSET :offset',
      params,
    );

    return (result.rows.map(_rowToMap).toList(), total);
  }

  Future<(List<Map<String, dynamic>>, int)> findDrugs({
    int limit = 20,
    int offset = 0,
    String? search,
    bool? active, // null = all, true = active only, false = inactive only
  }) async {
    // drugs is a standalone legacy table — not linked to catalog_items.
    final conditions = <String>[];
    final params = <String, dynamic>{'limit': limit, 'offset': offset};

    if (active != null) {
      conditions.add('is_active = :active');
      params['active'] = active ? 1 : 0;
    } else {
      conditions.add('is_active = 1'); // default: active only
    }

    if (search != null && search.isNotEmpty) {
      conditions.add('(drug_name LIKE :search OR drug_type LIKE :search)');
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

  Future<int> countDrugs({bool? active}) async {
    final conditions = <String>[];
    final params = <String, dynamic>{};

    if (active != null) {
      conditions.add('is_active = :active');
      params['active'] = active ? 1 : 0;
    } else {
      conditions.add('is_active = 1');
    }

    final where = 'WHERE ${conditions.join(' AND ')}';
    final result = await _pool.execute(
      'SELECT COUNT(*) as total FROM drugs $where',
      params,
    );
    return int.parse(result.rows.first.assoc()['total'] ?? '0');
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
