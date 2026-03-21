-- Migration 016: Create sessions table for JWT refresh tokens
-- Safe to re-run — uses CREATE TABLE IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS `sessions` (
  `session_id`         binary(16)   NOT NULL,
  `user_id`            binary(16)   NOT NULL,
  `refresh_token_hash` char(64)     NOT NULL,
  `role`               varchar(32)  NOT NULL DEFAULT 'staff',
  `created_at`         datetime     NOT NULL DEFAULT current_timestamp(),
  `expires_at`         datetime     NOT NULL,
  `revoked_at`         datetime     DEFAULT NULL,
  `last_used_at`       datetime     DEFAULT NULL,
  PRIMARY KEY (`session_id`),
  UNIQUE KEY `uq_refresh_token` (`refresh_token_hash`),
  KEY `idx_sessions_user_id` (`user_id`),
  CONSTRAINT `fk_sessions_user`
    FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
