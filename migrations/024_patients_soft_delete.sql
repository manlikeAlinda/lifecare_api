-- Migration 024: soft-delete support for patients (beneficiaries)
-- Idempotent — safe to run even if the column/index already exists.
--
-- Beneficiary deletion previously hard-deleted the patient row and their
-- encounters while leaving the shared wallet's ledger entries (which
-- reference wallet_id, not patient_id) untouched — severing the audit
-- trail for a wallet debit that remains on the books. Soft-deleting instead
-- keeps encounters/ledger history intact and queryable while hiding the
-- beneficiary from active reads.

DROP PROCEDURE IF EXISTS migration_024;

DELIMITER //
CREATE PROCEDURE migration_024()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND COLUMN_NAME  = 'deleted_at'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN deleted_at DATETIME(6) NULL AFTER relationship;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'patients'
      AND INDEX_NAME   = 'idx_patients_deleted_at'
  ) THEN
    ALTER TABLE patients
      ADD KEY idx_patients_deleted_at (deleted_at);
  END IF;
END //
DELIMITER ;

CALL migration_024();
DROP PROCEDURE IF EXISTS migration_024;
