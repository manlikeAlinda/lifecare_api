-- Migration 022: Patient self-service deposits (MTN MoMo, Card)
-- Each row tracks one top-up attempt from initiation through webhook confirmation.

CREATE TABLE IF NOT EXISTS deposits (
  deposit_id       BINARY(16)    NOT NULL,
  wallet_id        BINARY(16)    NOT NULL,
  patient_id       BINARY(16)    NOT NULL,
  amount_shillings INT UNSIGNED  NOT NULL,          -- full Uganda Shillings (no sub-unit)
  payment_method   VARCHAR(20)   NOT NULL,           -- MTN_MOMO | CARD
  status           VARCHAR(20)   NOT NULL DEFAULT 'PENDING', -- PENDING | SUCCESSFUL | FAILED | EXPIRED
  provider_ref     VARCHAR(128)  DEFAULT NULL,       -- MTN X-Reference-Id or Flutterwave tx_ref
  failure_reason   VARCHAR(512)  DEFAULT NULL,
  metadata         JSON          DEFAULT NULL,       -- raw provider response stored for audit
  created_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (deposit_id),
  INDEX idx_deposits_wallet_id   (wallet_id),
  INDEX idx_deposits_patient_id  (patient_id),
  INDEX idx_deposits_provider_ref(provider_ref),
  INDEX idx_deposits_status      (status),
  INDEX idx_deposits_created_at  (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
