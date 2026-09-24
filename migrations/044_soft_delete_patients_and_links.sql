-- Migration 044: soft-delete for patients and beneficiary links.
--
-- 1. patients.deleted_by — who soft-deleted the account. Staff "delete
--    patient" no longer hard-deletes (which erased encounters, wallet_ledger
--    and provider_transactions); it sets deleted_at/deleted_by instead, so
--    clinical and financial history always survives.
--
-- 2. beneficiary_account_links.unlinked_at/unlinked_by — removing a
--    beneficiary ends the link instead of DELETEing the row, keeping a
--    queryable history of who was on which account and when.
--    uq_beneficiary_current_link (one row per beneficiary, ever) becomes
--    uq_beneficiary_active_link on a generated column that is non-NULL only
--    while the link is active: at most one ACTIVE link per beneficiary,
--    any number of ended ones. A plain index on beneficiary_patient_id is
--    added first so fk_links_beneficiary always has a supporting index.
--
-- 3. Drops fk_patient_primary_account (ON DELETE CASCADE). It duplicated
--    fk_patients_primary (ON DELETE SET NULL) on the same column, and a
--    cascade would silently delete a primary's beneficiaries if a patients
--    row were ever DELETEd. fk_patients_primary stays.
--
-- 4. Drops the plain UNIQUE index `phone_e164` on patients. It overrides
--    idx_patients_phone_uniq (migration 034), which is unique only among
--    non-deleted rows — without this, a soft-deleted patient would block
--    that phone number from ever being registered again.
--
-- Idempotent: every step checks INFORMATION_SCHEMA first.

DROP PROCEDURE IF EXISTS migration_044;

DELIMITER //
CREATE PROCEDURE migration_044()
BEGIN
  -- 1 ──────────────────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'deleted_by'
  ) THEN
    ALTER TABLE patients ADD COLUMN deleted_by BINARY(16) NULL AFTER deleted_at;
  END IF;

  -- 2 ──────────────────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'beneficiary_account_links' AND COLUMN_NAME = 'unlinked_at'
  ) THEN
    ALTER TABLE beneficiary_account_links
      ADD COLUMN unlinked_at DATETIME(6) NULL AFTER linked_by,
      ADD COLUMN unlinked_by BINARY(16) NULL AFTER unlinked_at;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'beneficiary_account_links' AND COLUMN_NAME = 'active_beneficiary_key'
  ) THEN
    ALTER TABLE beneficiary_account_links
      ADD COLUMN active_beneficiary_key BINARY(16)
        GENERATED ALWAYS AS (CASE WHEN unlinked_at IS NULL THEN beneficiary_patient_id ELSE NULL END) PERSISTENT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'beneficiary_account_links' AND INDEX_NAME = 'idx_links_beneficiary'
  ) THEN
    ALTER TABLE beneficiary_account_links ADD KEY idx_links_beneficiary (beneficiary_patient_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'beneficiary_account_links' AND INDEX_NAME = 'uq_beneficiary_active_link'
  ) THEN
    ALTER TABLE beneficiary_account_links ADD UNIQUE KEY uq_beneficiary_active_link (active_beneficiary_key);
  END IF;

  IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'beneficiary_account_links' AND INDEX_NAME = 'uq_beneficiary_current_link'
  ) THEN
    ALTER TABLE beneficiary_account_links DROP INDEX uq_beneficiary_current_link;
  END IF;

  -- 3 ──────────────────────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS
    WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND CONSTRAINT_NAME = 'fk_patient_primary_account'
  ) THEN
    ALTER TABLE patients DROP FOREIGN KEY fk_patient_primary_account;
  END IF;

  -- 4 ──────────────────────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND INDEX_NAME = 'phone_e164' AND NON_UNIQUE = 0
  ) THEN
    ALTER TABLE patients DROP INDEX phone_e164;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND INDEX_NAME = 'idx_patients_phone'
  ) THEN
    ALTER TABLE patients ADD KEY idx_patients_phone (phone_e164);
  END IF;
END //
DELIMITER ;

CALL migration_044();
DROP PROCEDURE IF EXISTS migration_044;
