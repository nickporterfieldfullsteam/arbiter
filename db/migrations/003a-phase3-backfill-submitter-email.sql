-- =============================================================================
-- Migration 003a — Phase 3 Step C.1 (prerequisite): backfill submitter_email
-- from locked_vals JSONB for rows created after migration 001.
-- =============================================================================
--
-- BACKGROUND
-- ----------
-- Migration 001 added a dedicated submitter_email column and backfilled it from
-- locked_vals->>'__email__' for the 30 rows that existed at the time. However,
-- the main app's sbUpsertProject function continued to write emails only into
-- the JSONB locked_vals blob, never into the new column. As a result, rows
-- created after migration 001 have NULL/empty submitter_email but a valid
-- email in locked_vals->>'__email__'.
--
-- This migration re-runs the same backfill logic for the drift that's
-- accumulated since 001. It's a prerequisite for migration 003 (active-rep
-- enforcement), which relies on submitter_email being populated.
--
-- Idempotent: only updates rows where submitter_email is empty and JSONB email
-- is present.
-- =============================================================================

BEGIN;

-- Pre-flight count (returned here in the transaction as a visible result):
-- shows how many rows will be updated.
SELECT COUNT(*) AS rows_to_backfill
FROM projects
WHERE (submitter_email IS NULL OR submitter_email = '')
  AND (locked_vals->>'__email__') IS NOT NULL
  AND (locked_vals->>'__email__') <> '';

UPDATE projects
SET submitter_email = lower(locked_vals->>'__email__')
WHERE (submitter_email IS NULL OR submitter_email = '')
  AND (locked_vals->>'__email__') IS NOT NULL
  AND (locked_vals->>'__email__') <> '';

COMMIT;

-- Post-apply verification (run separately):
--   SELECT COUNT(*) AS still_missing
--   FROM projects
--   WHERE deleted_at IS NULL
--     AND (submitter_email IS NULL OR submitter_email = '')
--     AND (locked_vals->>'__email__') IS NOT NULL
--     AND (locked_vals->>'__email__') <> '';
-- Should return 0.
