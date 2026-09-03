-- Migration 036: identity document type selector
--
-- patients.national_id already stores the free-text ID value (any of
-- NIN/passport/refugee-ID). This adds only the discriminator column so
-- the UI can render one field with a type selector instead of three
-- separate columns — no new value column, id_type just labels the
-- existing national_id value.

DROP PROCEDURE IF EXISTS migration_036;

DELIMITER //
CREATE PROCEDURE migration_036()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'id_type'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN id_type
        ENUM('national_id','passport','refugee_id','other')
        NOT NULL DEFAULT 'national_id' AFTER national_id;
  END IF;
END //
DELIMITER ;

CALL migration_036();
DROP PROCEDURE IF EXISTS migration_036;
