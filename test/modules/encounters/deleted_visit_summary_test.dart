import 'package:test/test.dart';
import 'package:lifecare_api/modules/encounters/encounter_repository.dart';

void main() {
  test('deletedVisitSummary records what the visit was, for the audit log', () {
    final summary = deletedVisitSummary({
      'id': 'enc-1',
      'reference_number': 'REF-9',
      'patient_id': 'pat-1',
      'patient_name': 'Jane Doe',
      'dependent_id': 'dep-1',
      'dependent_name': 'Tom Doe',
      'visited_at': '2026-09-30 08:00:00',
      'total_cost': 14000,
      'diagnosis_category': 'respiratory',
      'services': [
        {'name': 'Consultation', 'quantity': 1},
      ],
      'medications': [
        {'name': 'Paracetamol', 'quantity': 2},
      ],
    });
    expect(summary['reference_number'], 'REF-9');
    expect(summary['patient_name'], 'Jane Doe');
    expect(summary['dependent_name'], 'Tom Doe');
    expect(summary['total_cost'], 14000);
    expect(summary['services'], ['Consultation x1']);
    expect(summary['medications'], ['Paracetamol x2']);
    expect(summary['diagnosis_category'], 'respiratory');
  });
}
