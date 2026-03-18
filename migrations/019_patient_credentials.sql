CREATE TABLE IF NOT EXISTS patient_credentials (
  credential_id   BINARY(16)    NOT NULL,
  patient_id      BINARY(16)    NOT NULL,
  phone_e164      VARCHAR(20)   NOT NULL,
  password_hash   VARCHAR(255)  NOT NULL,
  activation_pin  VARCHAR(20)   NULL,
  status          ENUM('pending_activation', 'active', 'suspended')
                                NOT NULL DEFAULT 'pending_activation',
  must_change_pw  TINYINT(1)    NOT NULL DEFAULT 0,
  created_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  last_login_at   DATETIME      NULL,
  PRIMARY KEY (credential_id),
  UNIQUE KEY idx_pc_patient  (patient_id),
  UNIQUE KEY idx_pc_phone    (phone_e164),
  KEY            idx_pc_status (status),
  CONSTRAINT fk_pc_patient
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
