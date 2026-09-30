-- Migration 046: how a deposit was paid.
--
-- wallet_ledger.payment_method — 'cash' | 'mobile_money' | 'card' | 'bank'.
--   Set by desk payments (POST /v1/wallets/:id/payments) and by Pesapal
--   deposits (from the provider's reported method). NULL on rows written
--   before this migration: the Deposits report shows those as
--   "Not recorded" rather than guessing.
-- wallet_ledger.payment_reference — the cashier's receipt / mobile-money
--   transaction ID / bank slip number, for reconciling against statements.
--
-- Idempotent: checks INFORMATION_SCHEMA first.

DROP PROCEDURE IF EXISTS migration_046;

DELIMITER //
CREATE PROCEDURE migration_046()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger'
      AND COLUMN_NAME = 'payment_method'
  ) THEN
    ALTER TABLE wallet_ledger ADD COLUMN payment_method VARCHAR(20) NULL AFTER reason;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger'
      AND COLUMN_NAME = 'payment_reference'
  ) THEN
    ALTER TABLE wallet_ledger ADD COLUMN payment_reference VARCHAR(64) NULL AFTER payment_method;
  END IF;
END //
DELIMITER ;

CALL migration_046();
DROP PROCEDURE IF EXISTS migration_046;
