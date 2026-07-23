import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/modules/catalog/catalog_repository.dart';
import 'package:lifecare_api/modules/encounters/encounter_pricing_resolver.dart';

class FakeCatalogPriceLookup implements CatalogPriceLookup {
  final Map<String, Map<String, dynamic>> services; // key: 'domain/id'
  final Map<int, Map<String, dynamic>> drugs;

  FakeCatalogPriceLookup({this.services = const {}, this.drugs = const {}});

  @override
  Future<Map<String, dynamic>?> findByDomainAndId(String domain, int id) async =>
      services['$domain/$id'];

  @override
  Future<Map<String, dynamic>?> findDrugById(int id) async => drugs[id];
}

void main() {
  group('EncounterPricingResolver.resolveServices', () {
    test('bills at the catalog rate even when the client sends unit_price: 0',
        () async {
      final catalog = FakeCatalogPriceLookup(services: {
        'dental/5': {'id': 5, 'name': 'Filling', 'rate': 50000},
      });
      final resolver = EncounterPricingResolver(catalog);

      final resolved = await resolver.resolveServices([
        {
          'domain': 'dental',
          'service_id': '5',
          'unit_price': 0,
          'price': 0,
          'total_price': 0,
          'quantity': 1,
        },
      ]);

      expect(resolved.single['unit_price'], 50000.0);
      expect(resolved.single['line_total'], 50000.0);
    });

    test('rejects an unknown (domain, id) with a 422 businessRule error',
        () async {
      final resolver = EncounterPricingResolver(FakeCatalogPriceLookup());

      expect(
        () => resolver.resolveServices([
          {'domain': 'dental', 'service_id': 999, 'quantity': 1},
        ]),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 422)),
      );
    });

    test('rejects a line missing domain', () async {
      final resolver = EncounterPricingResolver(FakeCatalogPriceLookup());

      expect(
        () => resolver.resolveServices([
          {'service_id': 5, 'quantity': 1},
        ]),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 422)),
      );
    });

    test('multiplies catalog rate by quantity', () async {
      final catalog = FakeCatalogPriceLookup(services: {
        'lab/12': {'id': 12, 'name': 'Blood test', 'rate': 20000},
      });
      final resolver = EncounterPricingResolver(catalog);

      final resolved = await resolver.resolveServices([
        {'domain': 'lab', 'service_id': 12, 'quantity': 3},
      ]);

      expect(resolved.single['line_total'], 60000.0);
    });
  });

  group('EncounterPricingResolver.resolveDrugs', () {
    test('bills at the catalog rate even when the client sends rate: 0',
        () async {
      final catalog = FakeCatalogPriceLookup(drugs: {
        7: {'id': 7, 'name': 'Paracetamol', 'price': 500},
      });
      final resolver = EncounterPricingResolver(catalog);

      final resolved = await resolver.resolveDrugs([
        {'drug_id': 7, 'rate': 0, 'quantity': 2},
      ]);

      expect(resolved.single['unit_price'], 500.0);
      expect(resolved.single['line_total'], 1000.0);
    });

    test('rejects an unknown drug_id with a 422 businessRule error', () async {
      final resolver = EncounterPricingResolver(FakeCatalogPriceLookup());

      expect(
        () => resolver.resolveDrugs([
          {'drug_id': 404, 'quantity': 1},
        ]),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 422)),
      );
    });
  });

  group('EncounterPricingResolver.sumTotal', () {
    test('sums resolved line totals', () {
      final lines = [
        {'line_total': 10.0},
        {'line_total': 5.5},
      ];
      expect(EncounterPricingResolver.sumTotal(lines), 15.5);
    });
  });
}
