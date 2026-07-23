-- Migration 025: catalog-authoritative pricing for encounter service lines
-- Idempotent — safe to run even if the columns already exist.
--
-- encounter_services.service_id is BINARY(16) (UUID) but the client's real
-- service catalog (dental_services, lab_services, imaging_services,
-- procedure_packages, laparoscopic_procedures, accommodation_services,
-- consultation_fees) uses per-table INT primary keys with no domain field
-- transmitted, so service_id could never actually resolve to a priced item.
-- Add domain + domain_item_id so the server can resolve and persist the
-- authoritative (domain, id) catalog reference used to compute the charge.

DROP PROCEDURE IF EXISTS migration_025;

DELIMITER //
CREATE PROCEDURE migration_025()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'encounter_services'
      AND COLUMN_NAME  = 'domain'
  ) THEN
    ALTER TABLE encounter_services
      ADD COLUMN domain VARCHAR(20) NULL AFTER service_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'encounter_services'
      AND COLUMN_NAME  = 'domain_item_id'
  ) THEN
    ALTER TABLE encounter_services
      ADD COLUMN domain_item_id INT NULL AFTER domain;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'encounter_services'
      AND INDEX_NAME   = 'idx_es_domain_item'
  ) THEN
    ALTER TABLE encounter_services
      ADD KEY idx_es_domain_item (domain, domain_item_id);
  END IF;

  -- service_id was always populated with a placeholder zero-UUID for real
  -- (domain-table) traffic since it never actually referenced a UUID-keyed
  -- catalog row. Make it nullable so new rows can stop writing that placeholder.
  ALTER TABLE encounter_services
    MODIFY COLUMN service_id BINARY(16) NULL;
END //
DELIMITER ;

CALL migration_025();
DROP PROCEDURE IF EXISTS migration_025;
