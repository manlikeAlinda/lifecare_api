-- Migration 021: add sub-patient (beneficiary) support to patients table
-- Adds: national_id (plain text), primary_account_id (FK to self), relationship

ALTER TABLE patients
  ADD COLUMN national_id   VARCHAR(50)  NULL AFTER national_id_hash,
  ADD COLUMN primary_account_id BINARY(16) NULL AFTER account_type,
  ADD COLUMN relationship  VARCHAR(64)  NULL AFTER primary_account_id,
  ADD KEY    idx_patients_primary (primary_account_id),
  ADD CONSTRAINT fk_patients_primary
    FOREIGN KEY (primary_account_id) REFERENCES patients (patient_id)
    ON DELETE SET NULL;
