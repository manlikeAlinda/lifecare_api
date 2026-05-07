-- Migration 023: Replace legacy deposits table with current schema.
-- The original table had different column names (user_id, amount_minor,
-- provider_tx_id, idempotency_key) that don't match the API code.
-- Safe to drop: the table only contains failed PENDING test rows.

DROP TABLE IF EXISTS deposits;

CREATE TABLE deposits (
  deposit_id       BINARY(16)    NOT NULL,
  wallet_id        BINARY(16)    NOT NULL,
  patient_id       BINARY(16)    NOT NULL,
  amount_shillings INT UNSIGNED  NOT NULL,
  payment_method   VARCHAR(20)   NOT NULL,
  status           VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
  provider_ref     VARCHAR(128)  DEFAULT NULL,
  failure_reason   VARCHAR(512)  DEFAULT NULL,
  metadata         JSON          DEFAULT NULL,
  created_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (deposit_id),
  INDEX idx_deposits_wallet_id    (wallet_id),
  INDEX idx_deposits_patient_id   (patient_id),
  INDEX idx_deposits_provider_ref (provider_ref),
  INDEX idx_deposits_status       (status),
  INDEX idx_deposits_created_at   (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
