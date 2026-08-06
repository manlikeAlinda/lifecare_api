-- Migration 026: seed a fixed "System" staff user, used as the actor on
-- audit_log rows for provider/webhook-originated writes (KYC verification
-- results, and any future automated state change) that have no real staff
-- or patient actor. Referenced by AppConfig.systemActorId — the UUID here
-- MUST match that constant exactly.
--
-- is_active = 0 and an unusable password hash: this account can never log
-- in, even if credentials were somehow guessed. It exists only to be
-- referenced as a foreign key value.
--
-- Idempotent — INSERT IGNORE is safe to re-run.

INSERT IGNORE INTO users
  (user_id, username, display_name, email, password_hash, password_alg, is_active)
VALUES
  (
    UNHEX(REPLACE('2f6554b5-a339-42cb-9011-de5e893aa112', '-', '')),
    'system',
    'System',
    NULL,
    -- Unusable placeholder — not a valid bcrypt hash of any real string.
    '$2a$12$0000000000000000000000000000000000000000000000000000',
    'bcrypt',
    0
  );
