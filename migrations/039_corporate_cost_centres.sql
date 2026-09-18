-- Migration 039: corporate cost centres
--
-- Corporate accounts need to attribute roster spend to internal
-- departments/cost centres for the analytics dashboard's spend breakdown.
-- Managed as a real table (not a free-typed string on patients) so a
-- corporate admin can list/rename/retire them without touching every row
-- that references one.

DROP PROCEDURE IF EXISTS migration_039;

DELIMITER //
CREATE PROCEDURE migration_039()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'cost_centres'
  ) THEN
    CREATE TABLE cost_centres (
      cost_centre_id       BINARY(16)    NOT NULL,
      corporate_account_id BINARY(16)    NOT NULL,
      name                 VARCHAR(100)  NOT NULL,
      is_active             TINYINT(1)    NOT NULL DEFAULT 1,
      created_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (cost_centre_id),
      UNIQUE KEY uq_cost_centre_name (corporate_account_id, name),
      KEY idx_cost_centre_account (corporate_account_id),
      CONSTRAINT fk_cost_centre_account
        FOREIGN KEY (corporate_account_id) REFERENCES patients (patient_id)
        ON DELETE CASCADE
    ) ENGINE=InnoDB;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'cost_centre_id'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN cost_centre_id BINARY(16) NULL AFTER primary_account_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
    WHERE TABLE_SCHEMA    = DATABASE()
      AND TABLE_NAME      = 'patients'
      AND CONSTRAINT_NAME = 'fk_patients_cost_centre'
      AND CONSTRAINT_TYPE = 'FOREIGN KEY'
  ) THEN
    ALTER TABLE patients
      ADD CONSTRAINT fk_patients_cost_centre
        FOREIGN KEY (cost_centre_id) REFERENCES cost_centres (cost_centre_id)
        ON DELETE SET NULL;
  END IF;
END //
DELIMITER ;

CALL migration_039();
DROP PROCEDURE IF EXISTS migration_039;
