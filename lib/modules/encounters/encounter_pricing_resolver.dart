import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/catalog/catalog_repository.dart';

/// Resolves encounter service/drug lines against the catalog so pricing is
/// always server-derived. Client-sent price/unit_price/total_price fields
/// are display hints only and are never read here.
class EncounterPricingResolver {
  final CatalogPriceLookup _catalogRepo;

  EncounterPricingResolver(this._catalogRepo);

  Future<List<Map<String, dynamic>>> resolveServices(
    List<Map<String, dynamic>> items,
  ) async {
    final resolved = <Map<String, dynamic>>[];
    for (final item in items) {
      final domain = (item['domain'] as String?)?.trim() ?? '';
      final rawId = item['service_id'] ?? item['id'];
      final itemId = _toPositiveInt(rawId);
      if (domain.isEmpty || itemId == null) {
        throw ApiError.businessRule(
            'Each service line requires a domain and service_id');
      }

      final catalogItem = await _catalogRepo.findByDomainAndId(domain, itemId);
      if (catalogItem == null) {
        throw ApiError.businessRule('Unknown service: $domain/$itemId');
      }

      final quantity = _toPositiveInt(item['quantity'] ?? 1);
      if (quantity == null) {
        throw ApiError.validationError('quantity must be a positive integer');
      }

      final unitPrice = _toDouble(catalogItem['rate']);
      resolved.add({
        'domain': domain,
        'domain_item_id': itemId,
        'service_name': catalogItem['name'] as String? ??
            item['service_name'] as String? ??
            item['name'] as String? ??
            '',
        'unit_price': unitPrice,
        'quantity': quantity,
        'line_total': unitPrice * quantity,
      });
    }
    return resolved;
  }

  Future<List<Map<String, dynamic>>> resolveDrugs(
    List<Map<String, dynamic>> items,
  ) async {
    final resolved = <Map<String, dynamic>>[];
    for (final item in items) {
      final drugId = _toPositiveInt(item['drug_id']);
      if (drugId == null) {
        throw ApiError.businessRule('Each drug line requires a drug_id');
      }

      final drug = await _catalogRepo.findDrugById(drugId);
      if (drug == null) {
        throw ApiError.businessRule('Unknown drug: $drugId');
      }

      final quantity = _toPositiveInt(item['quantity'] ?? 1);
      if (quantity == null) {
        throw ApiError.validationError('quantity must be a positive integer');
      }

      final unitPrice = _toDouble(drug['price'] ?? drug['rate']);
      resolved.add({
        'drug_id': drugId,
        'medication_name': drug['name'] as String? ??
            item['drug_name'] as String? ??
            item['medication_name'] as String? ??
            item['name'] as String? ??
            '',
        'dosage_instructions': item['dosage_instructions'],
        'unit_price': unitPrice,
        'quantity': quantity,
        'line_total': unitPrice * quantity,
      });
    }
    return resolved;
  }

  static double sumTotal(List<Map<String, dynamic>> lines) =>
      lines.fold(0.0, (sum, l) => sum + (l['line_total'] as double));

  static int? _toPositiveInt(dynamic v) {
    final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
    if (n == null || n <= 0) return null;
    return n;
  }

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
}
