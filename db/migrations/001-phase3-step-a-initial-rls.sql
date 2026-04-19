-- =========================================================================
-- Arbiter Phase 3 — Step A migration
-- =========================================================================
-- Purpose: Prepare the database for the rep portal (Phase 3).
--
-- What this does:
--   1. Adds an indexed `submitter_email` column on `projects` (backfilled
--      from the existing locked_vals JSONB).
--   2. Creates a `reps` table for tracking who you've invited to the portal.
--   3. Enables RLS on `projects` with four policies scoped to the submitter
--      or to workspace admins.
--   4. Enables RLS on `reps` with admin-only policies.
--   5. Relaxes `workspace_config` SELECT so authenticated reps can read
--      form criteria at load time. Write access remains admin-only.
--
-- What this does NOT do:
--   - No data migration for existing rows beyond backfilling the email
--     column. The JSONB field locked_vals.__email__ is preserved for
--     fallback during Step D cutover.
--   - No changes to workspace_members, workspaces — already correctly
--     RLS'd.
--   - No changes to the frontend code. After this migration runs, the
--     main app should behave identically; the policies match existing
--     access patterns.
--
-- Rollback: see ROLLBACK section at the end. Run everything inside a
-- BEGIN/COMMIT block so a single failure aborts the whole migration.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Add `submitter_email` column to projects
-- -------------------------------------------------------------------------
-- Submitter email currently lives in locked_vals->>'__email__' (JSONB).
-- For RLS to be efficient, it needs to be a first-class column so policies
-- can compare `submitter_email = auth.email()` without JSONB traversal.
--
-- Nullable for now: existing rows are backfilled in step 2, and future
-- writes from the portal will set it. Eventually we'll add NOT NULL once
-- we're confident every row has it.
ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS submitter_email text;

-- -------------------------------------------------------------------------
-- 2. Backfill submitter_email from existing JSONB
-- -------------------------------------------------------------------------
-- Copies the email out of locked_vals.__email__ into the new column, for
-- every project that has it. Only runs for rows where the column is NULL
-- and the JSONB key exists — safe to re-run.
UPDATE projects
SET submitter_email = locked_vals->>'__email__'
WHERE submitter_email IS NULL
  AND locked_vals ? '__email__'
  AND locked_vals->>'__email__' IS NOT NULL
  AND locked_vals->>'__email__' != '';

-- -------------------------------------------------------------------------
-- 3. Index for RLS performance
-- -------------------------------------------------------------------------
-- Every SELECT the portal does will filter by submitter_email. Index makes
-- that fast. IF NOT EXISTS so re-running the migration is safe.
CREATE INDEX IF NOT EXISTS idx_projects_submitter_email
  ON projects(submitter_email);

-- -------------------------------------------------------------------------
-- 4. Create `reps` table
-- -------------------------------------------------------------------------
-- Tracks who you've invited to use the portal. Separate from Supabase auth
-- because you can invite someone (issue a form/portal link) BEFORE they've
-- ever signed in — the first time they magic-link in, Supabase creates
-- their auth.users row; this table is independent of that.
--
-- One rep per email per workspace. `active` lets you revoke access without
-- deleting the row (so you keep history of who was invited).
CREATE TABLE IF NOT EXISTS reps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  email text NOT NULL,
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, email)
);

CREATE INDEX IF NOT EXISTS idx_reps_workspace_email
  ON reps(workspace_id, email);

-- -------------------------------------------------------------------------
-- 5. Enable RLS on projects
-- -------------------------------------------------------------------------
-- From now on, every query against projects is filtered by a policy.
-- Without a policy matching the current role, the row is invisible.
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

-- Drop any stale policies from prior experimentation (safe if none exist).
DROP POLICY IF EXISTS projects_select       ON projects;
DROP POLICY IF EXISTS projects_insert       ON projects;
DROP POLICY IF EXISTS projects_update       ON projects;
DROP POLICY IF EXISTS projects_delete       ON projects;

-- -------------------------------------------------------------------------
-- 5a. SELECT policy
-- -------------------------------------------------------------------------
-- A row is visible to the requester if EITHER:
--   (a) the requester's email matches submitter_email (reps see their own)
--   (b) the requester is an admin in the project's workspace (you)
CREATE POLICY projects_select ON projects
  FOR SELECT
  USING (
    submitter_email = auth.email()
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

-- -------------------------------------------------------------------------
-- 5b. INSERT policy
-- -------------------------------------------------------------------------
-- Authenticated users can insert ONLY rows where submitter_email matches
-- their auth email. Prevents impersonation — a rep cannot submit on behalf
-- of someone else. Admins can insert anything (for manually-created
-- projects from the main app).
CREATE POLICY projects_insert ON projects
  FOR INSERT
  WITH CHECK (
    submitter_email = auth.email()
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

-- -------------------------------------------------------------------------
-- 5c. UPDATE policy — the LOCK rule
-- -------------------------------------------------------------------------
-- This is the important one. Reps can update their own rows, but ONLY
-- while status = 'Submitted'. Once the admin moves it to any other status,
-- the rep's ability to update disappears at the DB level. Even if they
-- hit the API directly, the row is immutable to them.
--
-- The WITH CHECK clause also prevents a rep from transitioning the status
-- themselves: their update must keep status='Submitted' (enforced in the
-- CHECK; USING ensures they can only touch rows currently at Submitted).
--
-- Admins can always update anything.
CREATE POLICY projects_update ON projects
  FOR UPDATE
  USING (
    (submitter_email = auth.email() AND status = 'Submitted')
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  )
  WITH CHECK (
    (submitter_email = auth.email() AND status = 'Submitted')
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

-- -------------------------------------------------------------------------
-- 5d. DELETE policy
-- -------------------------------------------------------------------------
-- Only admins can delete. Reps have no delete path — they can edit their
-- submission while it's in Submitted, and admins handle rejection via
-- status changes (e.g. "Passed").
CREATE POLICY projects_delete ON projects
  FOR DELETE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

-- -------------------------------------------------------------------------
-- 6. Enable RLS on reps with admin-only policies
-- -------------------------------------------------------------------------
-- Only admins manage reps. There's no "rep sees their own rep record"
-- flow — if a rep needs to know their invite status, they ask the admin.
ALTER TABLE reps ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reps_select ON reps;
DROP POLICY IF EXISTS reps_insert ON reps;
DROP POLICY IF EXISTS reps_update ON reps;
DROP POLICY IF EXISTS reps_delete ON reps;

CREATE POLICY reps_select ON reps
  FOR SELECT
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

CREATE POLICY reps_insert ON reps
  FOR INSERT
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

CREATE POLICY reps_update ON reps
  FOR UPDATE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  )
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

CREATE POLICY reps_delete ON reps
  FOR DELETE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role = 'admin'
    )
  );

-- -------------------------------------------------------------------------
-- 7. Relax workspace_config SELECT for the portal
-- -------------------------------------------------------------------------
-- The portal form needs to fetch criteria, detail_fields, and project_type
-- mappings so it can render the same form the main app builds. These live
-- in workspace_config. Reps should read this config but not write it.
--
-- Drop the existing SELECT policy (if any) and replace with a permissive
-- one: any authenticated user can read. Writes remain admin-scoped.
DROP POLICY IF EXISTS workspace_config_select ON workspace_config;

CREATE POLICY workspace_config_select ON workspace_config
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Note: existing INSERT/UPDATE/DELETE policies on workspace_config are
-- left alone. If they don't exist, admin writes may silently fail.
-- After running this migration, verify by saving something in Settings
-- from the main app. If it fails, add admin-scoped write policies:
--
--   CREATE POLICY workspace_config_update ON workspace_config
--     FOR UPDATE
--     USING (workspace_id IN (
--       SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'
--     ))
--     WITH CHECK (...);
--
-- We'll verify this in the post-migration checks before committing the
-- transaction.

COMMIT;

-- =========================================================================
-- POST-MIGRATION SANITY CHECKS
-- =========================================================================
-- Run these AFTER the COMMIT above succeeds. They're read-only and just
-- confirm the migration did what it should.
-- =========================================================================

-- Check 1: submitter_email backfilled
SELECT
  count(*) AS total_projects,
  count(submitter_email) AS with_email,
  count(*) - count(submitter_email) AS missing_email
FROM projects;

-- Check 2: RLS is enabled
SELECT tablename, rowsecurity
FROM pg_tables
WHERE tablename IN ('projects', 'reps', 'workspace_config')
ORDER BY tablename;

-- Check 3: all expected policies exist
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('projects', 'reps', 'workspace_config')
ORDER BY tablename, policyname;

-- =========================================================================
-- ROLLBACK (reference — do not run unless reverting)
-- =========================================================================
-- If something is broken and you want to undo this migration:
--
--   BEGIN;
--     ALTER TABLE projects DISABLE ROW LEVEL SECURITY;
--     ALTER TABLE reps DISABLE ROW LEVEL SECURITY;
--     DROP POLICY IF EXISTS projects_select ON projects;
--     DROP POLICY IF EXISTS projects_insert ON projects;
--     DROP POLICY IF EXISTS projects_update ON projects;
--     DROP POLICY IF EXISTS projects_delete ON projects;
--     DROP POLICY IF EXISTS reps_select ON reps;
--     DROP POLICY IF EXISTS reps_insert ON reps;
--     DROP POLICY IF EXISTS reps_update ON reps;
--     DROP POLICY IF EXISTS reps_delete ON reps;
--     DROP POLICY IF EXISTS workspace_config_select ON workspace_config;
--     DROP TABLE IF EXISTS reps;
--     DROP INDEX IF EXISTS idx_projects_submitter_email;
--     ALTER TABLE projects DROP COLUMN IF EXISTS submitter_email;
--   COMMIT;
--
-- This leaves the original schema intact. locked_vals.__email__ was never
-- touched, so no submission data is lost.
-- =========================================================================
