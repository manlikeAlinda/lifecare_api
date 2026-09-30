wagwan 

## Database migrations

Schema changes live in `migrations/NNN_description.sql` (one folder; files in
`migrations/not_applied/` are history and never run). Apply them with the
runner, which records each one in `schema_migrations`:

```bash
dart run bin/migrate.dart --status        # what's applied / pending
dart run bin/migrate.dart                 # apply everything pending, in order
```

It uses the same `DB_*` settings as the API (`.env`). **Production, first
time only:** migrations up to 044 were applied by hand before the runner
existed, so record them without re-running them, then apply the rest:

```bash
dart run bin/migrate.dart --baseline 044
dart run bin/migrate.dart
```

Take a backup first (see the desktop repo's `BACKUP_RESTORE.md`). Every
migration from 044 onward is safe to re-run.
