# Database migrations

SQL files in this folder track schema changes to the Arbiter Supabase
project. They are applied in numeric order.

## Conventions

- **File naming:** `NNN-short-description.sql` where `NNN` is a zero-padded
  three-digit sequence number. Example: `001-phase3-step-a-initial-rls.sql`.
- **One concern per file.** Splitting related changes across files is fine
  if it gives you a natural checkpoint between them — e.g., "add column
  and backfill" vs. "switch app to use new column" can be separate.
- **Wrap everything in a transaction** (`BEGIN; ... COMMIT;`) so any
  single failure aborts the whole file and leaves the DB untouched.
- **Include sanity checks at the bottom.** After the `COMMIT`, a few
  read-only `SELECT` queries that confirm the migration did what it
  should. Run these manually after applying.
- **Include a rollback section** as SQL comments at the bottom of each
  file. Never auto-executed — it exists as a reference if a revert
  is needed.

## How to apply a migration

1. Open the Supabase dashboard → SQL Editor
2. Paste the migration file content
3. Review the comments top-to-bottom before running
4. Click **Run**
5. Scroll down to the sanity-check `SELECT`s and run each one
6. Do a manual smoke test of the main app (sign in, edit something)
7. If everything looks right, commit the migration file to git
   (if it isn't already) so the repo history matches the DB state

## Migration log

| # | File | Applied | Summary |
|---|------|---------|---------|
| 001 | `001-phase3-step-a-initial-rls.sql` | 2026-04-19 | Added `submitter_email` column, `reps` table, initial RLS policies on `projects` and `reps`, permissive SELECT on `workspace_config`. |
| 002 | `002-phase3-step-a-cleanup.sql` | 2026-04-19 | Consolidated overlapping policies, preserved `pm` role alongside `admin`, fixed silent bug in `workspace_config` write policy, tightened portal SELECT to scope by workspace membership or active rep. |

When you apply a new migration, update this table with the date and a
one-line summary. The point isn't bureaucracy — it's so future-you (or a
new machine) can tell at a glance "what state is my DB schema in?"

## When something goes wrong

Migrations use transactions, so failures during execution roll back
automatically and leave your DB untouched. Your options:

1. **If the migration failed mid-execution:** the transaction rolled back
   and you're fine. Fix the SQL and try again.
2. **If the migration succeeded but broke something:** run the rollback
   block at the bottom of the file. Rollbacks are SQL comments, not
   auto-executed, so you have to copy/paste into the SQL editor.
3. **If the rollback also breaks things:** restore from a Supabase DB
   backup. Dashboard → Database → Backups.

## Philosophy

These migrations are a record of decisions, not just commands. Read the
comments in each file — they explain why each step exists, which matters
more than what the SQL does once you're debugging something at 2 AM.
