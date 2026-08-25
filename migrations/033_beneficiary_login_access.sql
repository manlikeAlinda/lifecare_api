-- Migration 033: beneficiary account login & data isolation
--
-- Adds:
--   patients.is_minor              — static flag (set at creation, not
--                                     derived from DOB); minors never get
--                                     login credentials.
--   patients.login_access_status   — beneficiary login journey, separate
--                                     from patient_credentials.status (which
--                                     only exists once a credential row
--                                     does). Kept in lockstep by the service
--                                     layer at every transition.
--   beneficiary_login_requests     — one row per primary->beneficiary
--                                     login-access request, feeding the
--                                     admin queue.
--   encounters.reason /
--   encounters.reason_hidden       — medical reason on a visit, and a
--                                     beneficiary-settable flag hiding it
--                                     from the primary's view.
--
-- Idempotent — safe to run even if some columns/tables already exist,
-- matching the style of migrations 030-032.

DROP PROCEDURE IF EXISTS migration_033;

DELIMITER //
CREATE PROCEDURE migration_033()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'is_minor'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN is_minor TINYINT(1) NOT NULL DEFAULT 0 AFTER relationship;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'patients' AND COLUMN_NAME = 'login_access_status'
  ) THEN
    ALTER TABLE patients
      ADD COLUMN login_access_status
        ENUM('no_login','pending','active','suspended','expired')
        NOT NULL DEFAULT 'no_login' AFTER is_minor;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'encounters' AND COLUMN_NAME = 'reason'
  ) THEN
    ALTER TABLE encounters
      ADD COLUMN reason VARCHAR(255) NULL AFTER service_type;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'encounters' AND COLUMN_NAME = 'reason_hidden'
  ) THEN
    ALTER TABLE encounters
      ADD COLUMN reason_hidden TINYINT(1) NOT NULL DEFAULT 0 AFTER reason;
  END IF;
END //
DELIMITER ;

CALL migration_033();
DROP PROCEDURE IF EXISTS migration_033;

CREATE TABLE IF NOT EXISTS beneficiary_login_requests (
  request_id      BINARY(16)   NOT NULL,
  beneficiary_id  BINARY(16)   NOT NULL,
  primary_id      BINARY(16)   NOT NULL,
  status          ENUM('pending','approved','rejected','cancelled') NOT NULL DEFAULT 'pending',
  requested_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved_at     DATETIME     NULL,
  resolved_by     BINARY(16)   NULL,
  PRIMARY KEY (request_id),
  KEY idx_blr_status (status),
  KEY idx_blr_beneficiary (beneficiary_id),
  CONSTRAINT fk_blr_beneficiary FOREIGN KEY (beneficiary_id) REFERENCES patients (patient_id) ON DELETE CASCADE,
  CONSTRAINT fk_blr_primary FOREIGN KEY (primary_id) REFERENCES patients (patient_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
