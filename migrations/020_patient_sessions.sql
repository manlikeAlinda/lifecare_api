CREATE TABLE IF NOT EXISTS patient_sessions (
  session_id          BINARY(16)   NOT NULL,
  patient_id          BINARY(16)   NOT NULL,
  refresh_token_hash  CHAR(64)     NOT NULL,
  created_at          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at          DATETIME     NOT NULL,
  revoked_at          DATETIME     NULL,
  last_used_at        DATETIME     NULL,
  PRIMARY KEY (session_id),
  UNIQUE KEY idx_ps_token_hash (refresh_token_hash),
  KEY            idx_ps_patient  (patient_id),
  KEY            idx_ps_expires  (expires_at),
  CONSTRAINT fk_ps_patient
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
