-- Migration 035: link wallet_ledger entries back to the encounter that
-- caused them.
--
-- wallet_ledger currently has no way to answer "what was this deduction
-- for" — GET /v1/patient/transactions can show an amount and a type, but
-- never a reason. Adding a nullable encounter_id lets EncounterRepository
-- populate it at write time (create/update/delete-reversal) so the
-- transaction detail screen can show the originating visit.
--
-- Nullable and unconstrained by FK (matches this table's existing style —
-- wallet_id/initiated_by are also plain BINARY(16) with no FK) so deposits,
-- checkouts, and other non-encounter ledger types are unaffected.

DROP PROCEDURE IF EXISTS migration_035;

DELIMITER //
CREATE PROCEDURE migration_035()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger' AND COLUMN_NAME = 'encounter_id'
  ) THEN
    ALTER TABLE wallet_ledger
      ADD COLUMN encounter_id BINARY(16) NULL AFTER wallet_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wallet_ledger' AND INDEX_NAME = 'idx_wallet_ledger_encounter'
  ) THEN
    ALTER TABLE wallet_ledger
      ADD KEY idx_wallet_ledger_encounter (encounter_id);
  END IF;
END //
DELIMITER ;

CALL migration_035();
DROP PROCEDURE IF EXISTS migration_035;
