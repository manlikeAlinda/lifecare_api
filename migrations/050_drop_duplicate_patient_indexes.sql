-- Migration 050: drop duplicate indexes on patients.
--
-- Two pairs of indexes cover exactly the same column, so every insert and
-- update maintains each one twice for no read benefit:
--   idx_patients_primary  ==  idx_patients_primary_account_id  (primary_account_id)
--   patient_code          ==  uq_patients_patient_code         (UNIQUE patient_code)
-- Drops the first of each pair, but only while its twin exists — so the
-- foreign key on primary_account_id always keeps a supporting index and
-- patient_code always stays unique.
--
-- Idempotent: checks INFORMATION_SCHEMA first.

DROP PROCEDURE IF EXISTS migration_050;

DELIMITER //
CREATE PROCEDURE migration_050()
BEGIN
  IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND INDEX_NAME = 'idx_patients_primary'
  ) AND EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND INDEX_NAME = 'idx_patients_primary_account_id'
  ) THEN
    ALTER TABLE patients DROP INDEX idx_patients_primary;
  END IF;

  IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND INDEX_NAME = 'patient_code'
  ) AND EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND INDEX_NAME = 'uq_patients_patient_code' AND NON_UNIQUE = 0
  ) THEN
    ALTER TABLE patients DROP INDEX patient_code;
  END IF;
END //
DELIMITER ;

CALL migration_050();
DROP PROCEDURE IF EXISTS migration_050;
