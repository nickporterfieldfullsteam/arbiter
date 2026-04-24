-- =============================================================================
-- Migration 003 — Phase 3 Step C.1: enforce active-rep requirement on projects
-- =============================================================================
--
-- BACKGROUND
-- ----------
-- Through migration 002, submissions to projects were allowed by anyone whose
-- auth.email() matched submitter_email. Any authenticated Supabase user could
-- submit. This migration tightens that:
--
-- After this migration, a non-admin submitter must ALSO be registered in the
-- reps table (workspace_id match) with is_active = true. Admins and PMs of the
-- workspace continue to bypass this check.
--
-- Applies to INSERT and UPDATE. SELECT is intentionally left broader (reps see
-- their own history even after deactivation) and DELETE is already admin-only.
--
-- STRATEGY
-- --------
-- 1. Backfill reps from the distinct submitter_email values already in
--    projects, preserving the name from locked_vals->>'__submitter__' if
--    present. Backfilled reps default to is_active = true so existing
--    submitters don't lose access.
-- 2. Replace projects_insert and projects_update policies with ones that
--    require an active reps row (non-admin path) or admin/pm workspace
--    membership (admin path). Admin-path preserved exactly as migration 002.
-- 3. Before dropping old policies, we have the new ones ready so there's no
--    window where the table is unprotected.
--
-- SAFETY
-- ------
-- - Migration is wrapped in a transaction.
-- - Backfill is idempotent (ON CONFLICT DO NOTHING on (workspace_id, email)).
-- - A dry-run SELECT is provided as a comment at the top for pre-inspection.
-- - Rollback script is migrations/003-rollback.sql.
-- =============================================================================

-- Pre-flight inspection (run this first, separately, before applying):
--   SELECT DISTINCT p.workspace_id, p.submitter_email,
--                   (p.locked_vals->>'__submitter__') AS submitter_name,
--                   COUNT(*) AS submission_count
--   FROM projects p
--   WHERE p.submitter_email IS NOT NULL
--     AND p.submitter_email <> ''
--     AND p.deleted_at IS NULL
--     AND NOT EXISTS (
--       SELECT 1 FROM reps r
--       WHERE r.workspace_id = p.workspace_id
--         AND lower(r.email) = lower(p.submitter_email)
--     )
--   GROUP BY p.workspace_id, p.submitter_email, submitter_name
--   ORDER BY submission_count DESC;
--
-- Paste the results in your migration log before running the transaction.

BEGIN;

-- ----------------------------------------------------------------------------
-- 0) Ensure the unique constraint needed by ON CONFLICT. Without this index,
--    ON CONFLICT DO NOTHING silently no-ops every row on insert (observed
--    during original apply on 2026-04-23 — the backfill INSERT produced zero
--    rows with no error; had to be rerun manually). Creating this index
--    inside the migration makes the backfill idempotent and also structurally
--    prevents duplicate rep rows from being created later.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS reps_workspace_email_unique
  ON reps (workspace_id, lower(email));

-- ----------------------------------------------------------------------------
-- 1) Backfill: any email that has submitted but isn't in reps becomes an
--    active rep. Name pulled from the most-recent submission's locked_vals.
--    Using a CTE + SELECT DISTINCT ON to pick one name per email.
-- ----------------------------------------------------------------------------
INSERT INTO reps (workspace_id, email, name, is_active, created_at)
SELECT DISTINCT ON (p.workspace_id, lower(p.submitter_email))
  p.workspace_id,
  lower(p.submitter_email) AS email,
  COALESCE(NULLIF(p.locked_vals->>'__submitter__', ''), p.submitter_email) AS name,
  true AS is_active,
  now() AS created_at
FROM projects p
WHERE p.submitter_email IS NOT NULL
  AND p.submitter_email <> ''
  AND p.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM reps r
    WHERE r.workspace_id = p.workspace_id
      AND lower(r.email) = lower(p.submitter_email)
  )
ORDER BY p.workspace_id, lower(p.submitter_email), p.created_at DESC
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2) Replace policies. We drop and recreate atomically inside the transaction
--    so there's no window with no policy.
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS projects_insert ON projects;
DROP POLICY IF EXISTS projects_update ON projects;

-- INSERT: a non-admin submitter must be an active rep in the workspace;
-- admins/PMs of the workspace bypass.
CREATE POLICY projects_insert ON projects
  FOR INSERT
  WITH CHECK (
    -- Active rep in the workspace submitting under their own email
    (
      submitter_email = auth.email()
      AND EXISTS (
        SELECT 1 FROM reps r
        WHERE r.workspace_id = projects.workspace_id
          AND lower(r.email) = lower(auth.email())
          AND r.is_active = true
      )
    )
    OR
    -- Admin/PM of the workspace
    (
      workspace_id IN (
        SELECT workspace_members.workspace_id
        FROM workspace_members
        WHERE workspace_members.user_id = auth.uid()
          AND workspace_members.role = ANY (ARRAY['admin'::text, 'pm'::text])
      )
    )
  );

-- UPDATE: submitter can edit their Submitted row AND they must still be an
-- active rep; admins/PMs of the workspace bypass.
CREATE POLICY projects_update ON projects
  FOR UPDATE
  USING (
    (
      submitter_email = auth.email()
      AND status = 'Submitted'::text
      AND EXISTS (
        SELECT 1 FROM reps r
        WHERE r.workspace_id = projects.workspace_id
          AND lower(r.email) = lower(auth.email())
          AND r.is_active = true
      )
    )
    OR
    (
      workspace_id IN (
        SELECT workspace_members.workspace_id
        FROM workspace_members
        WHERE workspace_members.user_id = auth.uid()
          AND workspace_members.role = ANY (ARRAY['admin'::text, 'pm'::text])
      )
    )
  )
  WITH CHECK (
    (
      submitter_email = auth.email()
      AND status = 'Submitted'::text
      AND EXISTS (
        SELECT 1 FROM reps r
        WHERE r.workspace_id = projects.workspace_id
          AND lower(r.email) = lower(auth.email())
          AND r.is_active = true
      )
    )
    OR
    (
      workspace_id IN (
        SELECT workspace_members.workspace_id
        FROM workspace_members
        WHERE workspace_members.user_id = auth.uid()
          AND workspace_members.role = ANY (ARRAY['admin'::text, 'pm'::text])
      )
    )
  );

COMMIT;

-- ============================================================================
-- POST-APPLY SANITY CHECKS — run these after COMMIT, separately, and paste
-- results in the migration log.
-- ============================================================================
--
-- (a) Confirm policy count on projects is still 4:
--   SELECT policyname, cmd FROM pg_policies WHERE tablename = 'projects'
--   ORDER BY policyname;
--
-- (b) Confirm every email that has submitted is now an active rep or an
--     admin/pm member (should return 0 rows; any rows indicate orphans):
--   SELECT DISTINCT p.workspace_id, p.submitter_email
--   FROM projects p
--   WHERE p.submitter_email IS NOT NULL
--     AND p.submitter_email <> ''
--     AND p.deleted_at IS NULL
--     AND NOT EXISTS (
--       SELECT 1 FROM reps r
--       WHERE r.workspace_id = p.workspace_id
--         AND lower(r.email) = lower(p.submitter_email)
--         AND r.is_active = true
--     )
--     AND NOT EXISTS (
--       SELECT 1 FROM workspace_members wm
--       JOIN auth.users u ON u.id = wm.user_id
--       WHERE wm.workspace_id = p.workspace_id
--         AND wm.role IN ('admin', 'pm')
--         AND lower(u.email) = lower(p.submitter_email)
--     );
--
-- (c) Count backfilled reps (should match the dry-run count from pre-flight):
--   SELECT COUNT(*) FROM reps
--   WHERE created_at >= now() - interval '5 minutes';
--
-- ============================================================================
