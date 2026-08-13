-- Ad carousel content, managed via the desktop admin app's Ads Management
-- page, served to the mobile home-screen carousel via the public GET /v1/ads
-- endpoint (filtered to active + within date range there).
--
-- Matches what's actually live (applied manually via phpMyAdmin ahead of
-- this file): target_url is VARCHAR(1000), not 512; created_by is NOT NULL
-- with an FK to users(user_id) — safe here (unlike audit_log.actor_user_id)
-- because ads are only ever created by a staff admin via the desktop app,
-- never by a patient.
CREATE TABLE IF NOT EXISTS ads (
  ad_id             BINARY(16)    NOT NULL PRIMARY KEY,
  title             VARCHAR(200)  NOT NULL,
  body              VARCHAR(500)  DEFAULT NULL,
  cta_label         VARCHAR(50)   DEFAULT NULL,
  target_url        VARCHAR(1000) DEFAULT NULL,
  background_color  VARCHAR(7)    DEFAULT NULL COMMENT 'Hex color, e.g. #4B2E83',
  display_order     INT           NOT NULL DEFAULT 0,
  start_date        DATE          NOT NULL,
  end_date          DATE          NOT NULL,
  is_active         TINYINT(1)    NOT NULL DEFAULT 1,
  deleted_at        DATETIME(6)   DEFAULT NULL,
  created_by        BINARY(16)    NOT NULL,
  created_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  KEY idx_ads_public_read (is_active, start_date, end_date, display_order),
  KEY idx_ads_deleted_at (deleted_at),
  CONSTRAINT fk_ads_created_by FOREIGN KEY (created_by) REFERENCES users (user_id)
);
