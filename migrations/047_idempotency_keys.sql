-- Migration 047: idempotency keys for writes that move money.
--
-- The desktop sends one key per form (a UUID made when the form opens) and
-- reuses it on every retry of that form. When a request's response is lost
-- (dropped connection) and the user resubmits, the server finds the key and
-- returns the original visit / payment instead of charging or crediting a
-- second time. NULL for rows written without a key (older clients,
-- system-generated rows); UNIQUE ignores NULLs.
--
--   encounters.idempotency_key     — POST /v1/encounters
--   wallet_ledger.idempotency_key  — POST /v1/wallets/:id/payments
--
-- Idempotent: checks INFORMATION_SCHEMA first.

DROP PROCEDURE IF EXISTS migration_047;

DELIMITER //
CREATE PROCEDURE migration_047()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'encounters'
      AND COLUMN_NAME = 'idempotency_key'
  ) THEN
    ALTER TABLE encounters
      ADD COLUMN idempotency_key VARCHAR(64) NULL,
      ADD UNIQUE INDEX uq_encounters_idempotency_key (idempotency_key);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger'
      AND COLUMN_NAME = 'idempotency_key'
  ) THEN
    ALTER TABLE wallet_ledger
      ADD COLUMN idempotency_key VARCHAR(64) NULL,
      ADD UNIQUE INDEX uq_wallet_ledger_idempotency_key (idempotency_key);
  END IF;
END //
DELIMITER ;

CALL migration_047();
DROP PROCEDURE IF EXISTS migration_047;
