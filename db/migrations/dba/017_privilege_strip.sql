-- DBA Migration 017: Strip dangerous global privileges from the app DB user
--
-- Run as root/DBA — NOT as the application user.
-- Replace 'app_user'@'%' with your actual application database username
-- (check with: SELECT user, host FROM mysql.user;)
--
-- These privileges are not needed by the API and create unnecessary risk.

-- Identify your app user first:
-- SELECT user, host, Super_priv, File_priv, Shutdown_priv FROM mysql.user;

SET @app_user = 'app_user';   -- ← change this to your actual username
SET @app_host = '%';           -- ← change if your user has a specific host

-- Strip dangerous global privileges.
-- Errors on already-absent privileges are safe to ignore.
REVOKE FILE          ON *.*   FROM 'app_user'@'%';
REVOKE SUPER         ON *.*   FROM 'app_user'@'%';
REVOKE SHUTDOWN      ON *.*   FROM 'app_user'@'%';
REVOKE PROCESS       ON *.*   FROM 'app_user'@'%';
REVOKE RELOAD        ON *.*   FROM 'app_user'@'%';
REVOKE REPLICATION SLAVE   ON *.* FROM 'app_user'@'%';
REVOKE REPLICATION CLIENT  ON *.* FROM 'app_user'@'%';
REVOKE CREATE USER   ON *.*   FROM 'app_user'@'%';
REVOKE GRANT OPTION  ON *.*   FROM 'app_user'@'%';

FLUSH PRIVILEGES;
