-- Migration 043: TIN as a valid id_type for corporate accounts
--
-- Corporate account registration needs to record a URA Tax Identification
-- Number (TIN) instead of a National ID. patients.id_type (migration 036)
-- already discriminates what national_id/nat_id_enc hold for a given row
-- ('national_id'/'passport'/'refugee_id'/'other') — this adds 'tin' as a
-- fifth value rather than introducing a separate tax_id column, since a TIN
-- is structurally the same kind of fact (one identity value whose meaning
-- depends on id_type), just for a different account_type.

DROP PROCEDURE IF EXISTS migration_043;

DELIMITER //
CREATE PROCEDURE migration_043()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients'
      AND COLUMN_NAME = 'id_type' AND COLUMN_TYPE LIKE '%''tin''%'
  ) THEN
    ALTER TABLE patients
      MODIFY COLUMN id_type
        ENUM('national_id','passport','refugee_id','other','tin')
        NOT NULL DEFAULT 'national_id';
  END IF;
END //
DELIMITER ;

CALL migration_043();
DROP PROCEDURE IF EXISTS migration_043;
