-- Wallet spend/debit transactions (checkout). Client-generated idempotency_key
-- + UNIQUE(wallet_id, idempotency_key) makes retries of the same attempt safe
-- (no double debit) without a separate idempotency-key table.
CREATE TABLE IF NOT EXISTS checkout_transactions (
  checkout_id      BINARY(16)    NOT NULL PRIMARY KEY,
  wallet_id        BINARY(16)    NOT NULL,
  patient_id       BINARY(16)    NOT NULL,
  amount_shillings INT           NOT NULL,
  description      VARCHAR(255)  NOT NULL,
  reference_id     VARCHAR(100)  DEFAULT NULL,
  idempotency_key  VARCHAR(100)  NOT NULL,
  status           VARCHAR(20)   NOT NULL DEFAULT 'POSTED',
  created_at       DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_checkout_wallet_idempotency (wallet_id, idempotency_key),
  KEY idx_checkout_patient (patient_id),
  KEY idx_checkout_wallet (wallet_id)
);
