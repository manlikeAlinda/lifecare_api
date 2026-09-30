-- Migration 017: Fix role_key casing and ensure required roles exist
--
-- Problem: the DB has role_key = 'ADMIN' (uppercase) but the API checks
-- role == 'admin' (lowercase). This causes isAdmin to always be false,
-- breaking all admin-only routes and the user management page.
--
-- Safe to re-run — UPDATE and INSERT IGNORE are both idempotent.

-- 1. Fix the admin role key to lowercase so the API can match it.
UPDATE roles SET role_key = 'admin', role_name = 'Administrator'
WHERE UPPER(role_key) = 'ADMIN';

-- 2. Ensure a 'staff' role exists with the correct key.
INSERT IGNORE INTO roles (role_key, role_name)
VALUES ('staff', 'Staff');
