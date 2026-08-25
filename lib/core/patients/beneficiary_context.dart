/// True when [patientRow] (a row from PatientRepository) is a beneficiary
/// (sub-account), not a primary account holder.
///
/// Single source of truth — replaces the copy-pasted
/// `requester?['primary_account_id'] != null` checks that used to be
/// scattered across lib/app.dart and patient_service.dart.
bool isBeneficiaryRow(Map<String, dynamic>? patientRow) =>
    patientRow?['primary_account_id'] != null;
