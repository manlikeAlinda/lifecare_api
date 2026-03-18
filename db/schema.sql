-- ============================================================
-- LifeCare Database Schema
-- MySQL 8.0
-- ============================================================

CREATE DATABASE IF NOT EXISTS lifecare
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE lifecare;

-- ============================================================
-- IAM
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
  id             BINARY(16)                       NOT NULL,
  username       VARCHAR(100)                     NOT NULL,
  email          VARCHAR(255)                     NULL,
  full_name      VARCHAR(255)                     NOT NULL,
  password_hash  VARCHAR(255)                     NOT NULL,
  hash_algorithm ENUM('sha256','bcrypt')          NOT NULL DEFAULT 'bcrypt',
  role           ENUM('admin','staff')            NOT NULL DEFAULT 'staff',
  is_active      TINYINT(1)                       NOT NULL DEFAULT 1,
  created_at     DATETIME                         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME                         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_username (username),
  UNIQUE KEY uq_email    (email)
) ENGINE=InnoDB;

-- Default admin account (password: ChangeMe123!)
-- Replace this hash before production deployment
INSERT IGNORE INTO users (id, username, full_name, password_hash, hash_algorithm, role)
VALUES (
  UNHEX(REPLACE('00000000-0000-0000-0000-000000000001', '-', '')),
  'admin',
  'System Administrator',
  '$2b$12$placeholderHashReplaceBeforeDeployment000000000000000000',
  'bcrypt',
  'admin'
);

CREATE TABLE IF NOT EXISTS sessions (
  id                  BINARY(16)   NOT NULL,
  user_id             BINARY(16)   NOT NULL,
  refresh_token_hash  VARCHAR(64)  NOT NULL,
  created_at          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at          DATETIME     NOT NULL,
  revoked_at          DATETIME     NULL,
  device_info         VARCHAR(500) NULL,
  ip_address          VARCHAR(45)  NULL,
  PRIMARY KEY (id),
  KEY idx_refresh_token (refresh_token_hash),
  KEY idx_user_sessions (user_id),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- Patients
-- ============================================================

CREATE TABLE IF NOT EXISTS patients (
  id             BINARY(16)                          NOT NULL,
  patient_number VARCHAR(50)                         NULL,
  first_name     VARCHAR(100)                        NOT NULL,
  last_name      VARCHAR(100)                        NOT NULL,
  date_of_birth  DATE                                NULL,
  gender         ENUM('male','female','other')       NULL,
  phone          VARCHAR(20)                         NULL,
  email          VARCHAR(255)                        NULL,
  address        TEXT                                NULL,
  is_active      TINYINT(1)                          NOT NULL DEFAULT 1,
  created_by     BINARY(16)                          NULL,
  created_at     DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_patient_number (patient_number),
  KEY idx_last_name  (last_name),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dependents (
  id             BINARY(16)                          NOT NULL,
  patient_id     BINARY(16)                          NOT NULL,
  first_name     VARCHAR(100)                        NOT NULL,
  last_name      VARCHAR(100)                        NOT NULL,
  date_of_birth  DATE                                NULL,
  gender         ENUM('male','female','other')       NULL,
  relationship   VARCHAR(50)                         NULL,
  is_active      TINYINT(1)                          NOT NULL DEFAULT 1,
  created_at     DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_dependent_patient (patient_id),
  CONSTRAINT fk_dependents_patient FOREIGN KEY (patient_id) REFERENCES patients (id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- Wallets & Ledger (append-only ledger pattern)
-- ============================================================

CREATE TABLE IF NOT EXISTS wallets (
  id         BINARY(16) NOT NULL,
  patient_id BINARY(16) NOT NULL,
  created_at DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_wallet_patient (patient_id),
  CONSTRAINT fk_wallets_patient FOREIGN KEY (patient_id) REFERENCES patients (id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS wallet_ledger (
  id               BINARY(16)                                                 NOT NULL,
  wallet_id        BINARY(16)                                                 NOT NULL,
  transaction_type ENUM('deposit','refund','adjustment','deduction','debt_created') NOT NULL,
  amount           DECIMAL(15,2)                                              NOT NULL,
  balance_before   DECIMAL(15,2)                                              NOT NULL,
  balance_after    DECIMAL(15,2)                                              NOT NULL,
  reference_type   VARCHAR(50)                                                NULL,
  reference_id     BINARY(16)                                                 NULL,
  notes            TEXT                                                       NULL,
  created_by       BINARY(16)                                                 NULL,
  created_at       DATETIME                                                   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_ledger_wallet     (wallet_id),
  KEY idx_ledger_created_at (created_at),
  CONSTRAINT fk_ledger_wallet FOREIGN KEY (wallet_id) REFERENCES wallets (id) ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ============================================================
-- Catalog
-- ============================================================

CREATE TABLE IF NOT EXISTS catalog_items (
  id          BINARY(16)              NOT NULL,
  code        VARCHAR(50)             NULL,
  name        VARCHAR(255)            NOT NULL,
  category    VARCHAR(100)            NOT NULL,
  unit        VARCHAR(50)             NULL,
  price       DECIMAL(15,2)           NOT NULL DEFAULT 0.00,
  item_type   ENUM('service','drug')  NOT NULL,
  description TEXT                    NULL,
  is_active   TINYINT(1)              NOT NULL DEFAULT 1,
  created_at  DATETIME                NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME                NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_catalog_code (code),
  KEY idx_catalog_type     (item_type),
  KEY idx_catalog_category (category)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS drugs (
  id             BINARY(16)   NOT NULL,
  catalog_item_id BINARY(16)  NOT NULL,
  generic_name   VARCHAR(255) NULL,
  brand_name     VARCHAR(255) NULL,
  dosage_form    VARCHAR(100) NULL,
  strength       VARCHAR(100) NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_drugs_catalog FOREIGN KEY (catalog_item_id) REFERENCES catalog_items (id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- Encounters
-- ============================================================

CREATE TABLE IF NOT EXISTS encounters (
  id               BINARY(16)                         NOT NULL,
  encounter_number VARCHAR(50)                         NULL,
  patient_id       BINARY(16)                          NOT NULL,
  encounter_date   DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP,
  encounter_type   VARCHAR(50)                         NULL,
  provider         VARCHAR(255)                        NULL,
  notes            TEXT                                NULL,
  status           ENUM('open','closed','cancelled')  NOT NULL DEFAULT 'open',
  total_amount     DECIMAL(15,2)                       NOT NULL DEFAULT 0.00,
  wallet_ledger_id BINARY(16)                          NULL,
  created_by       BINARY(16)                          NULL,
  created_at       DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       DATETIME                            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_encounter_number (encounter_number),
  KEY idx_encounter_patient (patient_id),
  KEY idx_encounter_date    (encounter_date),
  KEY idx_encounter_status  (status),
  CONSTRAINT fk_encounters_patient FOREIGN KEY (patient_id) REFERENCES patients (id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS encounter_services (
  id             BINARY(16)    NOT NULL,
  encounter_id   BINARY(16)    NOT NULL,
  catalog_item_id BINARY(16)   NOT NULL,
  quantity       INT            NOT NULL DEFAULT 1,
  unit_price     DECIMAL(15,2) NOT NULL,
  total_price    DECIMAL(15,2) NOT NULL,
  notes          TEXT           NULL,
  PRIMARY KEY (id),
  KEY idx_enc_services_encounter (encounter_id),
  CONSTRAINT fk_enc_services_encounter FOREIGN KEY (encounter_id)    REFERENCES encounters    (id) ON DELETE CASCADE,
  CONSTRAINT fk_enc_services_catalog   FOREIGN KEY (catalog_item_id) REFERENCES catalog_items (id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS encounter_medications (
  id                   BINARY(16)    NOT NULL,
  encounter_id         BINARY(16)    NOT NULL,
  catalog_item_id      BINARY(16)    NOT NULL,
  quantity             INT            NOT NULL DEFAULT 1,
  unit_price           DECIMAL(15,2) NOT NULL,
  total_price          DECIMAL(15,2) NOT NULL,
  dosage_instructions  TEXT           NULL,
  notes                TEXT           NULL,
  PRIMARY KEY (id),
  KEY idx_enc_meds_encounter (encounter_id),
  CONSTRAINT fk_enc_meds_encounter FOREIGN KEY (encounter_id)    REFERENCES encounters    (id) ON DELETE CASCADE,
  CONSTRAINT fk_enc_meds_catalog   FOREIGN KEY (catalog_item_id) REFERENCES catalog_items (id) ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ============================================================
-- Audit Log
-- ============================================================

CREATE TABLE IF NOT EXISTS audit_log (
  id          BINARY(16)    NOT NULL,
  user_id     BINARY(16)    NULL,
  session_id  BINARY(16)    NULL,
  action      VARCHAR(100)  NOT NULL,
  target_type VARCHAR(100)  NOT NULL,
  target_id   VARCHAR(36)   NULL,
  details_json JSON         NULL,
  ip_address  VARCHAR(45)   NULL,
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_audit_user       (user_id),
  KEY idx_audit_target     (target_type, target_id),
  KEY idx_audit_created_at (created_at)
) ENGINE=InnoDB;

-- ============================================================
-- Sample catalog data (optional seed)
-- ============================================================

INSERT IGNORE INTO catalog_items (id, code, name, category, unit, price, item_type) VALUES
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000001','-','')), 'CONS-001', 'General Consultation',     'consultation', 'visit',  500.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000002','-','')), 'CONS-002', 'Specialist Consultation',  'consultation', 'visit', 1000.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000003','-','')), 'LAB-001',  'Full Blood Count',         'laboratory',   'test',   300.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000004','-','')), 'LAB-002',  'Liver Function Test',      'laboratory',   'test',   450.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000005','-','')), 'XRAY-001', 'Chest X-Ray',              'imaging',      'scan',   600.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000006','-','')), 'DENT-001', 'Dental Consultation',      'dental',       'visit',  400.00, 'service'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000007','-','')), 'DRG-001',  'Paracetamol 500mg',        'analgesic',    'tablet',  20.00, 'drug'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000008','-','')), 'DRG-002',  'Amoxicillin 500mg',        'antibiotic',   'tablet',  45.00, 'drug'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000009','-','')), 'DRG-003',  'Metformin 500mg',          'antidiabetic', 'tablet',  30.00, 'drug'),
  (UNHEX(REPLACE('10000000-0000-0000-0000-000000000010','-','')), 'DRG-004',  'Amlodipine 5mg',           'antihypertensive','tablet',55.00,'drug');

INSERT IGNORE INTO drugs (id, catalog_item_id, generic_name, brand_name, dosage_form, strength) VALUES
  (UNHEX(REPLACE('20000000-0000-0000-0000-000000000001','-','')), UNHEX(REPLACE('10000000-0000-0000-0000-000000000007','-','')), 'Paracetamol',  'Panadol',   'tablet', '500mg'),
  (UNHEX(REPLACE('20000000-0000-0000-0000-000000000002','-','')), UNHEX(REPLACE('10000000-0000-0000-0000-000000000008','-','')), 'Amoxicillin',  'Amoxil',    'tablet', '500mg'),
  (UNHEX(REPLACE('20000000-0000-0000-0000-000000000003','-','')), UNHEX(REPLACE('10000000-0000-0000-0000-000000000009','-','')), 'Metformin',    'Glucophage','tablet', '500mg'),
  (UNHEX(REPLACE('20000000-0000-0000-0000-000000000004','-','')), UNHEX(REPLACE('10000000-0000-0000-0000-000000000010','-','')), 'Amlodipine',   'Norvasc',   'tablet', '5mg');
