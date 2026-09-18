-- Migration 041: coded diagnosis category on encounters
--
-- The corporate analytics clinical endpoint needs to aggregate visits by
-- diagnosis without ever selecting a beneficiary-identifying or free-text
-- field (encounters.reason). A short, coded internal taxonomy captured at
-- encounter time — not derived from `reason` (free text is both a bigger
-- categorization task and a re-identification risk in a small cohort) and
-- not full ICD-10 (no clinical coding workflow exists in this app today).

DROP PROCEDURE IF EXISTS migration_041;

DELIMITER //
CREATE PROCEDURE migration_041()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'encounters' AND COLUMN_NAME = 'diagnosis_category'
  ) THEN
    ALTER TABLE encounters
      ADD COLUMN diagnosis_category
        ENUM(
          'respiratory',
          'gastrointestinal',
          'musculoskeletal',
          'cardiovascular',
          'dermatological',
          'infectious_disease',
          'reproductive_maternal',
          'mental_health',
          'injury_trauma',
          'chronic_disease_management',
          'preventive_wellness',
          'other'
        )
        NULL AFTER service_type;
  END IF;
END //
DELIMITER ;

CALL migration_041();
DROP PROCEDURE IF EXISTS migration_041;
