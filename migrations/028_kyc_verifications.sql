-- Migration 028: KYC verification. Targets `patients`, not `users` — KYC is
-- about the patient's identity, not the staff account.
CREATE TABLE IF NOT EXISTS kyc_verifications (
  kyc_id            BINARY(16)    NOT NULL,
  patient_id        BINARY(16)    NOT NULL,
  -- VARCHAR not ENUM — matches the live wallet_ledger.type convention
  -- (see WalletRepository's schema-reality comment) over db/schema.sql's
  -- stale ENUM style, so a future status value never needs a migration.
  status            VARCHAR(20)   NOT NULL DEFAULT 'SUBMITTED',
    -- SUBMITTED | VERIFIED | REJECTED | MANUAL_REVIEW
  provider          VARCHAR(64)   DEFAULT NULL,
  provider_job_id   VARCHAR(256)  DEFAULT NULL,
  national_id       VARCHAR(32)   DEFAULT NULL,
  full_name         VARCHAR(255)  DEFAULT NULL,
  date_of_birth     DATE          DEFAULT NULL,
  selfie_url        VARCHAR(512)  DEFAULT NULL,
  id_front_url      VARCHAR(512)  DEFAULT NULL,
  id_back_url       VARCHAR(512)  DEFAULT NULL,
  rejection_reason  VARCHAR(512)  DEFAULT NULL,
  verified_at       DATETIME(6)   DEFAULT NULL,
  submitted_at      DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  created_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (kyc_id),
  KEY idx_kyc_patient (patient_id),
  KEY idx_kyc_status  (status),
  KEY idx_kyc_job     (provider_job_id),
  CONSTRAINT fk_kyc_patient FOREIGN KEY (patient_id)
    REFERENCES patients (patient_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE patients
  ADD COLUMN kyc_status VARCHAR(20) NOT NULL DEFAULT 'NONE' AFTER national_id;
  -- NONE | PENDING | VERIFIED | REJECTED
