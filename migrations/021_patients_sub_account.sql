-- Migration 021: add sub-patient (beneficiary) support to patients table
-- Idempotent — safe to run even if some columns/indexes already exist.

DROP PROCEDURE IF EXISTS migration_021;

DELIMITER //
CREATE PROCEDURE migration_021()
BEGIN
  -- national_id (plain text, replaces the varbinary national_id_hash for new records)
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND COLUMN_NAME  = 'national_id'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN national_id VARCHAR(50) NULL AFTER national_id_hash;
  END IF;

  -- primary_account_id (self-referencing FK; NULL = primary account)
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND COLUMN_NAME  = 'primary_account_id'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN primary_account_id BINARY(16) NULL AFTER account_type;
  END IF;

  -- relationship (e.g. "Spouse", "Child")
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND COLUMN_NAME  = 'relationship'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN relationship VARCHAR(64) NULL AFTER primary_account_id;
  END IF;

  -- index on primary_account_id for fast beneficiary lookups
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND INDEX_NAME   = 'idx_patients_primary'
  ) THEN
    ALTER TABLE patients
      ADD KEY idx_patients_primary (primary_account_id);
  END IF;

  -- FK constraint (ON DELETE SET NULL so deleting a primary account orphans
  -- beneficiaries rather than cascade-deleting them)
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
    WHERE TABLE_SCHEMA      = DATABASE()
      AND TABLE_NAME        = 'patients'
      AND CONSTRAINT_NAME   = 'fk_patients_primary'
      AND CONSTRAINT_TYPE   = 'FOREIGN KEY'
  ) THEN
    ALTER TABLE patients
      ADD CONSTRAINT fk_patients_primary
        FOREIGN KEY (primary_account_id) REFERENCES patients (patient_id)
        ON DELETE SET NULL;
  END IF;
END //
DELIMITER ;

CALL migration_021();
DROP PROCEDURE IF EXISTS migration_021;
