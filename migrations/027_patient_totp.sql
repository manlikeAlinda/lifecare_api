-- Migration 027: TOTP 2FA fields on patient_credentials (not `users` —
-- patients authenticate through patient_credentials).
ALTER TABLE patient_credentials
  ADD COLUMN totp_secret  VARBINARY(128) DEFAULT NULL AFTER activation_pin,
  ADD COLUMN totp_enabled TINYINT(1)     NOT NULL DEFAULT 0 AFTER totp_secret;
