-- Migration 018: Remove duplicate staff role assignments from admin users
--
-- Some users were assigned both 'admin' and 'staff' roles. The API only
-- reads one role per user (the first JOIN result), so dual assignments
-- produce non-deterministic role resolution. Admins should only have admin.
--
-- Run AFTER 017_seed_roles.sql (requires role_key = 'admin' to exist).
-- Safe to re-run — DELETE is a no-op if no duplicates remain.

DELETE ur_staff
FROM user_roles ur_staff
INNER JOIN roles r_staff
  ON ur_staff.role_id = r_staff.role_id AND r_staff.role_key = 'staff'
WHERE EXISTS (
  SELECT 1
  FROM user_roles ur_admin
  INNER JOIN roles r_admin
    ON ur_admin.role_id = r_admin.role_id AND r_admin.role_key = 'admin'
  WHERE ur_admin.user_id = ur_staff.user_id
);
