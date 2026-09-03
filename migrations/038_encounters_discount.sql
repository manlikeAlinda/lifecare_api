-- Migration 038: discount on encounters (visits)
--
-- encounters.total_cost keeps its existing meaning — the actual
-- wallet-debited amount, i.e. post-discount — so every existing consumer
-- (wallet_ledger, reports, dashboard) keeps working unchanged.
-- discount_shillings is additive metadata for the invoice line only.

DROP PROCEDURE IF EXISTS migration_038;

DELIMITER //
CREATE PROCEDURE migration_038()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'encounters' AND COLUMN_NAME = 'discount_shillings'
  ) THEN
    ALTER TABLE encounters
      ADD COLUMN discount_shillings INT NOT NULL DEFAULT 0 AFTER total_cost;
  END IF;
END //
DELIMITER ;

CALL migration_038();
DROP PROCEDURE IF EXISTS migration_038;
