# Database — Project 02

PostgreSQL 17 (`postgres:17.5-alpine`), one instance, holding a single `notes` table.

## Schema

| Column | Type | Notes |
|---|---|---|
| `id` | `SERIAL PRIMARY KEY` | Auto-incrementing note id |
| `body` | `TEXT NOT NULL` | The note itself |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | Set by the database, not the app |

## Two things create this table, on purpose

| Path | When it runs | Why it exists |
|---|---|---|
| [`init.sql`](init.sql), mounted from a ConfigMap into `/docker-entrypoint-initdb.d/` | **Once**, on first initialisation of an empty data directory | Teaches ConfigMap-as-a-file (stage 05), and seeds the welcome notes |
| `CREATE TABLE IF NOT EXISTS` in `notes-api` at startup | Every API pod start, retried while Postgres boots | Keeps the API working in stage 03, before any ConfigMap exists |

Both are idempotent, so running both is safe. The overlap is not sloppiness —
it is what lets each stage stand on its own.

> **The gotcha worth remembering:** `/docker-entrypoint-initdb.d/` scripts run
> **only when `PGDATA` is empty**. Once the database has a persistent volume,
> editing `init.sql` and restarting the pod does *nothing*. People lose hours to
> this. Schema changes after day one are the job of a migration tool, not the
> entrypoint directory.

## Connecting by hand

```bash
kubectl exec -it postgres-0 -n notes-platform -- psql -U notes -d notes
```

```sql
\dt                         -- list tables
\d notes                    -- describe the table, including the index
SELECT * FROM notes;        -- the rows the UI is showing you
SELECT pg_size_pretty(pg_database_size('notes'));
\q
```

## Configuration the image expects

| Variable | Source in this project | Purpose |
|---|---|---|
| `POSTGRES_DB` | ConfigMap (stage 05) | Database created on first init |
| `POSTGRES_USER` | ConfigMap (stage 05) | Superuser created on first init |
| `POSTGRES_PASSWORD` | **Secret** (stage 06) | Password for that user — required, the image refuses to start without it |
| `PGDATA` | Deployment / StatefulSet | Set to a **subdirectory** of the mount point (see below) |

> ⚠️ **Why `PGDATA` points at a subdirectory.** Mounting a volume at
> `/var/lib/postgresql/data` directly leaves a `lost+found` directory in it on
> some filesystems, and Postgres refuses to initialise a non-empty directory.
> Setting `PGDATA=/var/lib/postgresql/data/pgdata` sidesteps it. This is the
> single most common "my Postgres pod won't start on Kubernetes" cause.
