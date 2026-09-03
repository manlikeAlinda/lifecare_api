-- Migration 037: reason/notes on wallet_ledger entries
--
-- WalletService.createTransaction already accepted a `notes` field from the
-- client but never persisted it anywhere — not on wallet_ledger, not in
-- audit_log (whose hand-rolled insert hardcoded details to '{}'). This
-- closes that gap so admin balance adjustments always have a durable,
-- queryable reason attached to the ledger row itself.

DROP PROCEDURE IF EXISTS migration_037;

DELIMITER //
CREATE PROCEDURE migration_037()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger' AND COLUMN_NAME = 'reason'
  ) THEN
    ALTER TABLE wallet_ledger
      ADD COLUMN reason VARCHAR(255) NULL AFTER failure_reason;
  END IF;
END //
DELIMITER ;

CALL migration_037();
DROP PROCEDURE IF EXISTS migration_037;
