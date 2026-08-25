-- Migration 034: global phone-number uniqueness across all patients
--
-- patient_credentials.phone_e164 is already UNIQUE (migration 019) — that
-- covers anyone who already has login credentials. patients.phone_e164
-- itself has no such constraint, so two non-deleted patient rows (e.g. two
-- beneficiaries, or a beneficiary and an unrelated primary) can currently
-- share a phone number as long as neither/only one has credentials.
--
-- *** DO NOT APPLY BLINDLY. *** Run this check against prod first and
-- resolve any conflicts manually — the ADD UNIQUE KEY below will fail if
-- any exist:
--
--   SELECT phone_e164, COUNT(*) FROM patients
--   WHERE deleted_at IS NULL AND phone_e164 IS NOT NULL
--   GROUP BY phone_e164 HAVING COUNT(*) > 1;
--
-- The generated column is NULL for deleted/phone-less rows — MySQL unique
-- indexes allow multiple NULLs, so those never collide.

DROP PROCEDURE IF EXISTS migration_034;

DELIMITER //
CREATE PROCEDURE migration_034()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'phone_uniq_key'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN phone_uniq_key VARCHAR(20)
        GENERATED ALWAYS AS (CASE WHEN deleted_at IS NULL THEN phone_e164 ELSE NULL END) VIRTUAL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND INDEX_NAME = 'idx_patients_phone_uniq'
  ) THEN
    ALTER TABLE patients
      ADD UNIQUE KEY idx_patients_phone_uniq (phone_uniq_key);
  END IF;
END //
DELIMITER ;

CALL migration_034();
DROP PROCEDURE IF EXISTS migration_034;
