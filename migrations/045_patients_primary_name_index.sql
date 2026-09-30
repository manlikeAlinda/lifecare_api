-- Migration 045: composite index for the beneficiary typeahead.
--
-- GET /v1/patients/:id/dependents/search filters on primary_account_id,
-- text-matches full_name / patient_code / phone_e164, and sorts by
-- (full_name, patient_code) with a small LIMIT. This index covers the
-- filter AND the whole sort, so MariaDB walks one account's rows already in
-- order and stops once it has enough matches — no filesort. Measured on a
-- 3,000-row local copy: the planner picks this index unprompted and the
-- plan drops "Using filesort"; a two-column (primary_account_id, full_name)
-- index was ignored and still sorted, so it's not used here.
--
-- A leading-wildcard LIKE ('%q%') can't seek on full_name; the gain is the
-- account-scoped, pre-ordered scan.
--
-- Idempotent: checks INFORMATION_SCHEMA first.

DROP PROCEDURE IF EXISTS migration_045;

DELIMITER //
CREATE PROCEDURE migration_045()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND INDEX_NAME = 'idx_patients_primary_name'
  ) THEN
    ALTER TABLE patients
      ADD INDEX idx_patients_primary_name (primary_account_id, full_name, patient_code);
  END IF;
END //
DELIMITER ;

CALL migration_045();
DROP PROCEDURE IF EXISTS migration_045;
