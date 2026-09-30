# Migrations that were never applied — do not run

`bin/migrate.dart` only reads numbered files directly in `migrations/`, so
nothing here is ever run. They are kept for history.

| File | Why it was never applied |
|------|--------------------------|
| `017_seed_roles.sql` | Inserts BINARY(16) UUID `role_id`s; production's `roles.role_id` is SMALLINT (1/2/5). Roles were seeded another way. |
| `018_fix_staff_role_assignments.sql` | Depends on 017's roles existing in the form it expects, which they don't. |
| `dba_017_privilege_strip.sql` | DBA-only privilege restrictions, run by hand as the database owner — not by the app's migration user. |

(Moved here from `db/migrations/` when the two migration folders were
merged; `016_create_sessions.sql` moved to `migrations/`, as production
already recorded it as applied.)
