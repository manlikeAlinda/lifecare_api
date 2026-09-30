-- Migration 049: deleted accounts are never active.
--
-- softDelete used to set deleted_at but leave is_active = 1, so any query
-- or screen checking is_active alone showed deleted accounts as active.
-- softDelete now clears is_active too; this backfills rows deleted before.
--
-- Idempotent: re-running updates nothing.

UPDATE patients SET is_active = 0 WHERE deleted_at IS NOT NULL AND is_active = 1;
