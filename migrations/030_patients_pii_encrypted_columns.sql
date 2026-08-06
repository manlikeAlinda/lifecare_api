-- Dual-write columns for AES-256-GCM encrypted PII. Plaintext columns are
-- kept — this is additive only, no plaintext removal in this pass. Reads
-- keep using the plaintext columns until a verified backfill + soak period.
ALTER TABLE patients
  ADD COLUMN phone_enc       VARBINARY(512) DEFAULT NULL AFTER phone_e164,
  ADD COLUMN national_id_enc VARBINARY(512) DEFAULT NULL AFTER national_id;
