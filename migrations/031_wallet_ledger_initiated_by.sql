-- Attributes each ledger entry to the patient who initiated it (nullable —
-- staff/encounter-driven entries and pre-existing rows have no single patient
-- initiator). Lets a beneficiary's transaction view be scoped to only the
-- entries they personally triggered (checkouts), while the primary account
-- holder keeps seeing the full shared-wallet history.
ALTER TABLE wallet_ledger
  ADD COLUMN initiated_by BINARY(16) DEFAULT NULL AFTER wallet_id;
