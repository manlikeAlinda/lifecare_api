/// True when [patientRow] (a row from PatientRepository) is a beneficiary
/// (sub-account), not a primary account holder.
///
/// Single source of truth — replaces the copy-pasted
/// `requester?['primary_account_id'] != null` checks that used to be
/// scattered across lib/app.dart and patient_service.dart.
bool isBeneficiaryRow(Map<String, dynamic>? patientRow) =>
    patientRow?['primary_account_id'] != null;

/// True when [patientRow] is a corporate account's own primary holder
/// (never a beneficiary — a corporate account's beneficiaries carry
/// `account_type: 'dependent'`, not `'corporate'`, so the primary_account_id
/// check is redundant in practice but kept as defense-in-depth).
bool isCorporatePrimaryRow(Map<String, dynamic>? patientRow) =>
    patientRow?['account_type'] == 'corporate' &&
    patientRow?['primary_account_id'] == null;
