-- Migration 017: Seed required system roles
-- Run this once on the production database.
-- Uses INSERT IGNORE so it is safe to re-run.

INSERT IGNORE INTO roles (role_key, role_name)
VALUES
  ('admin', 'Administrator'),
  ('staff', 'Staff');
