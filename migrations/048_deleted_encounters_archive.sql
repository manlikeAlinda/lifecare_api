-- Migration 048: keep deleted visits.
--
-- Deleting a visit used to DELETE the encounters row (and, by cascade, its
-- services and medications) with an empty audit entry — the clinical record
-- was gone for good. Now EncounterRepository.delete first copies the full
-- visit (row + service lines + drug lines, as JSON) into this table inside
-- the same transaction, so a mistaken delete can be inspected and restored.
-- The live encounters table keeps its meaning (deleted visits drop out of
-- every report and count, as before), so no read query had to change.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS deleted_encounters (
  encounter_id  BINARY(16)   NOT NULL,
  patient_id    BINARY(16)   NOT NULL,
  dependent_id  BINARY(16)   NULL,
  snapshot      LONGTEXT     NOT NULL,
  deleted_by    BINARY(16)   NOT NULL,
  deleted_at    DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (encounter_id),
  KEY idx_deleted_encounters_patient (patient_id),
  KEY idx_deleted_encounters_deleted_at (deleted_at)
) ENGINE=InnoDB;
