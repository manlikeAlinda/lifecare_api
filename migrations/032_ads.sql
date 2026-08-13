-- Ad carousel content, managed via the desktop admin app's Ads Management
-- page, served to the mobile home-screen carousel via the public GET /v1/ads
-- endpoint (filtered to active + within date range there).
CREATE TABLE IF NOT EXISTS ads (
  ad_id             BINARY(16)    NOT NULL PRIMARY KEY,
  title             VARCHAR(200)  NOT NULL,
  body              VARCHAR(500)  DEFAULT NULL,
  cta_label         VARCHAR(50)   DEFAULT NULL,
  target_url        VARCHAR(512)  DEFAULT NULL,
  background_color  VARCHAR(7)    DEFAULT NULL,
  display_order     INT           NOT NULL DEFAULT 0,
  start_date        DATE          NOT NULL,
  end_date          DATE          NOT NULL,
  is_active         TINYINT(1)    NOT NULL DEFAULT 1,
  created_by        BINARY(16)    DEFAULT NULL,
  created_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  deleted_at        DATETIME(6)   DEFAULT NULL,
  KEY idx_ads_active_dates (deleted_at, is_active, start_date, end_date),
  KEY idx_ads_display_order (display_order)
);
