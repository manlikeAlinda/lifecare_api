-- Migration 042: decouple the beneficiary-to-account relationship from the
-- beneficiary's own clinical/financial patient record.
--
-- Until now, patients.primary_account_id conflated two facts in one row:
--   (1) "this row IS a person with clinical/financial history", and
--   (2) "this row is currently on account X's roster".
-- Removing a beneficiary soft-deleted the clinical row itself
-- (PatientRepository.softDeleteSubPatient set patients.deleted_at) — the
-- exact soft-delete-flag pattern being retired for beneficiary records.
--
-- This migration adds a dedicated relationship table so "remove beneficiary"
-- becomes a real hard DELETE of the relationship row (no deleted_at/
-- is_active flag, ever, on this table), while the beneficiary's own
-- patients row — and everything that FKs to it (encounters,
-- encounter_services, encounter_medications, wallet_ledger, deposits,
-- checkout_transactions) — is left completely untouched, satisfying
-- clinical/financial retention obligations independent of relationship
-- status.
--
-- patients.primary_account_id is KEPT as a denormalized "who's currently
-- managing this beneficiary" cache — existing read queries (findAll,
-- findSubPatients, wallet lookups, analytics) still read it directly, and
-- rewriting every one of those to join beneficiary_account_links instead is
-- a larger change than this migration's scope. beneficiary_account_links is
-- the new source of truth for the relationship's own lifecycle (linked_at,
-- who linked it, the historical fact that a link existed at all).
--
-- Idempotent — CREATE TABLE IF NOT EXISTS, and both backfills are guarded so
-- re-running this file is safe.

CREATE TABLE IF NOT EXISTS beneficiary_account_links (
  link_id                BINARY(16)   NOT NULL,
  beneficiary_patient_id BINARY(16)   NOT NULL,
  primary_account_id     BINARY(16)   NOT NULL,
  relationship           VARCHAR(50)  NULL,
  cost_centre_id         BINARY(16)   NULL,
  linked_at              DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  linked_by              BINARY(16)   NULL,
  PRIMARY KEY (link_id),
  -- A beneficiary is on at most one roster at a time. Re-linking after a
  -- removal inserts a new row (the old one was hard-deleted), never an
  -- update — this constraint is what makes "current link exists" a clean
  -- existence check rather than a status column to filter on.
  UNIQUE KEY uq_beneficiary_current_link (beneficiary_patient_id),
  KEY idx_links_primary (primary_account_id),
  CONSTRAINT fk_links_beneficiary FOREIGN KEY (beneficiary_patient_id)
    REFERENCES patients (patient_id),
  CONSTRAINT fk_links_primary FOREIGN KEY (primary_account_id)
    REFERENCES patients (patient_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Backfill 1: currently-linked beneficiaries (never soft-deleted) get a link
-- row reflecting their existing relationship. linked_at uses their own
-- created_at as the best available proxy — this system has never recorded
-- "when were they added to this account" separately from "when was this
-- patient row created"; the two happened atomically at creation.
INSERT INTO beneficiary_account_links
  (link_id, beneficiary_patient_id, primary_account_id, relationship, cost_centre_id, linked_at)
SELECT
  UNHEX(REPLACE(UUID(), '-', '')),
  p.patient_id,
  p.primary_account_id,
  p.relationship,
  p.cost_centre_id,
  p.created_at
FROM patients p
WHERE p.primary_account_id IS NOT NULL
  AND p.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM beneficiary_account_links l
    WHERE l.beneficiary_patient_id = p.patient_id
  );

-- Backfill 2: beneficiaries already removed under the old soft-delete
-- pattern (primary_account_id set, deleted_at set by softDeleteSubPatient).
-- No current link is created for them — they are not on anyone's roster
-- today. What we preserve is the FACT that a removal happened, as an
-- audit_log entry (the durable record of the event going forward, not a
-- flag on the operational row), then clear primary_account_id so no stale
-- roster-membership signal remains on the row.
--
-- Deliberately NOT clearing patients.deleted_at here: doing so would risk
-- colliding with idx_patients_phone_uniq if the same phone number has since
-- been reused by a different live patient. These specific historical rows
-- are grandfathered as-is; only the relationship model changes going
-- forward. Their clinical/financial history was never touched by the old
-- pattern in the first place (softDeleteSubPatient only ever set
-- patients.deleted_at — encounters/wallet_ledger were always left intact),
-- so nothing about retention is at risk here either way.
INSERT INTO audit_log
  (audit_id, user_id, actor_user_id, action_type, entity_type, request_id,
   action, target_type, target_id, details)
SELECT
  UNHEX(REPLACE(UUID(), '-', '')),
  NULL,
  UNHEX(REPLACE('2f6554b5-a339-42cb-9011-de5e893aa112', '-', '')), -- AppConfig.systemActorId
  'UNLINK_BENEFICIARY', 'patient', 'migration-042',
  'UNLINK_BENEFICIARY', 'patient', p.patient_id,
  JSON_OBJECT(
    'migrated_from', 'patients.deleted_at',
    'primary_account_id', LOWER(CONCAT(
      SUBSTR(HEX(p.primary_account_id),1,8),'-',SUBSTR(HEX(p.primary_account_id),9,4),'-',
      SUBSTR(HEX(p.primary_account_id),13,4),'-',SUBSTR(HEX(p.primary_account_id),17,4),'-',
      SUBSTR(HEX(p.primary_account_id),21))),
    'original_deleted_at', p.deleted_at
  )
FROM patients p
WHERE p.primary_account_id IS NOT NULL
  AND p.deleted_at IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM audit_log a
    WHERE a.target_id = p.patient_id AND a.action = 'UNLINK_BENEFICIARY'
      AND a.request_id = 'migration-042'
  );

UPDATE patients
SET primary_account_id = NULL
WHERE primary_account_id IS NOT NULL
  AND deleted_at IS NOT NULL;
