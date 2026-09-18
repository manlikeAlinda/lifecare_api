-- Migration 040: allocated budget ceiling for corporate accounts
--
-- Distinct from actual spend/deposits (wallet_ledger) — this is a
-- separately admin-set figure (e.g. an HR-negotiated quarterly allowance)
-- that the analytics dashboard's utilization % compares actual spend
-- against. NULL until an admin sets one.

DROP PROCEDURE IF EXISTS migration_040;

DELIMITER //
CREATE PROCEDURE migration_040()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'allocated_budget_shillings'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN allocated_budget_shillings DECIMAL(15,2) NULL AFTER cost_centre_id;
  END IF;
END //
DELIMITER ;

CALL migration_040();
DROP PROCEDURE IF EXISTS migration_040;
