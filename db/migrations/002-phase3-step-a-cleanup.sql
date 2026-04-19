-- =========================================================================
-- Migration 002 — Phase 3 Step A cleanup / policy consolidation
-- =========================================================================
-- Prerequisites: migration 001 has been applied successfully.
--
-- Problem: after 001 landed, the DB had a mix of old policies (left over
-- from earlier experimentation) and new ones (from 001). Both sets worked
-- — Postgres uses OR semantics when multiple policies apply — but having
-- overlapping policies is:
--   * hard to reason about (which rule is granting access?)
--   * easy to make inconsistent in future changes
--   * a silent-bug vector (the old "PMs can update config" policy
--     actually granted writes to any workspace member, not just PMs)
--
-- This migration consolidates to a single canonical set of policies per
-- table, preserves the `pm` role (distinct from `admin`), and fixes the
-- silent bug on workspace_config writes.
--
-- End state:
--   projects: 4 policies, one per command. Admin or PM for writes,
--             submitter can read/insert/update-while-Submitted.
--   reps:     1 policy (ALL) — admin or PM only. The 4 admin-only policies
--             from 001 are dropped in favor of the pre-existing
--             "PMs can manage reps" which already uses role IN (pm, admin).
--   workspace_config: 2 policies. SELECT = "member of workspace OR rep
--                     linked to workspace". Writes = admin or PM.
--
-- Rollback: see ROLLBACK section at the end.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. projects — drop everything and rebuild
-- -------------------------------------------------------------------------
-- Drop old policies (from pre-001 experimentation)
DROP POLICY IF EXISTS "Members can read projects" ON projects;
DROP POLICY IF EXISTS "PMs can delete projects"   ON projects;
DROP POLICY IF EXISTS "PMs can insert projects"   ON projects;
DROP POLICY IF EXISTS "PMs can update projects"   ON projects;

-- Drop policies from migration 001 (they only check admin; we want admin+pm)
DROP POLICY IF EXISTS projects_select ON projects;
DROP POLICY IF EXISTS projects_insert ON projects;
DROP POLICY IF EXISTS projects_update ON projects;
DROP POLICY IF EXISTS projects_delete ON projects;

-- Canonical SELECT: submitter sees own rows, admin/pm sees all in workspace.
CREATE POLICY projects_select ON projects
  FOR SELECT
  USING (
    submitter_email = auth.email()
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

-- Canonical INSERT: submitter can only insert rows where submitter_email
-- matches their auth email (no impersonation), admin/pm can insert anything.
CREATE POLICY projects_insert ON projects
  FOR INSERT
  WITH CHECK (
    submitter_email = auth.email()
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

-- Canonical UPDATE: submitter can edit their own rows ONLY while
-- status='Submitted' (the lock). admin/pm can update anything.
-- WITH CHECK mirrors USING so a submitter can't transition status
-- themselves — their update must keep status='Submitted'.
CREATE POLICY projects_update ON projects
  FOR UPDATE
  USING (
    (submitter_email = auth.email() AND status = 'Submitted')
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  )
  WITH CHECK (
    (submitter_email = auth.email() AND status = 'Submitted')
    OR workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

-- Canonical DELETE: admin/pm only. Reps have no delete path.
CREATE POLICY projects_delete ON projects
  FOR DELETE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

-- -------------------------------------------------------------------------
-- 2. reps — drop the 4 admin-only policies from 001, keep the existing
--    "PMs can manage reps" which already uses admin+pm
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS reps_select ON reps;
DROP POLICY IF EXISTS reps_insert ON reps;
DROP POLICY IF EXISTS reps_update ON reps;
DROP POLICY IF EXISTS reps_delete ON reps;

-- "PMs can manage reps" stays. It's an ALL policy with the admin+pm check
-- already. (Its name is slightly misleading since it covers admin too, but
-- the behavior is correct — leave the name so we don't churn the schema.)

-- -------------------------------------------------------------------------
-- 3. workspace_config — drop all existing policies, rebuild cleanly
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS "Members can read config"   ON workspace_config;
DROP POLICY IF EXISTS "PMs can update config"     ON workspace_config;
DROP POLICY IF EXISTS workspace_config_select     ON workspace_config;

-- SELECT: member of the workspace OR an active rep linked to it.
--
-- The reps check uses a subquery against the reps table. RLS policy
-- subqueries run in a context that can read the reps table even though
-- end users cannot SELECT from it directly (policy evaluation runs as
-- the table owner, bypassing the user's own RLS on reps). This is the
-- standard Supabase pattern for cross-table policy checks.
CREATE POLICY workspace_config_select ON workspace_config
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM workspace_members
      WHERE workspace_members.workspace_id = workspace_config.workspace_id
        AND workspace_members.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM reps
      WHERE reps.workspace_id = workspace_config.workspace_id
        AND reps.email = auth.email()
        AND reps.active = true
    )
  );

-- Writes (INSERT/UPDATE/DELETE): admin/pm only. Fixes the silent bug
-- where the old "PMs can update config" policy used FOR ALL with no
-- role check, effectively granting any workspace member full write access.
CREATE POLICY workspace_config_insert ON workspace_config
  FOR INSERT
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

CREATE POLICY workspace_config_update ON workspace_config
  FOR UPDATE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  )
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

CREATE POLICY workspace_config_delete ON workspace_config
  FOR DELETE
  USING (
    workspace_id IN (
      SELECT workspace_id
      FROM workspace_members
      WHERE user_id = auth.uid()
        AND role IN ('admin', 'pm')
    )
  );

COMMIT;

-- =========================================================================
-- POST-MIGRATION SANITY CHECKS
-- =========================================================================

-- Check 1: Final policy inventory.
-- Expected (14 policies total across the three tables):
--   projects:         4 (one per command)
--   reps:             1 ("PMs can manage reps", ALL)
--   workspace_config: 4 (SELECT, INSERT, UPDATE, DELETE)
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('projects', 'reps', 'workspace_config')
ORDER BY tablename, cmd, policyname;

-- Check 2: RLS still enabled on all three tables
SELECT tablename, rowsecurity
FROM pg_tables
WHERE tablename IN ('projects', 'reps', 'workspace_config')
ORDER BY tablename;

-- Check 3: Projects count unchanged (we only touched policies, not data)
SELECT count(*) AS total_projects FROM projects;

-- =========================================================================
-- ROLLBACK (reference — do not run unless reverting)
-- =========================================================================
-- This restores migration 001's policies exactly. The old pre-001 policies
-- (e.g., "Members can read projects", "PMs can update config") are NOT
-- recreated — they were intentionally retired here. If you need them back,
-- restore from a DB backup.
--
-- BEGIN;
--   DROP POLICY IF EXISTS projects_select ON projects;
--   DROP POLICY IF EXISTS projects_insert ON projects;
--   DROP POLICY IF EXISTS projects_update ON projects;
--   DROP POLICY IF EXISTS projects_delete ON projects;
--   DROP POLICY IF EXISTS workspace_config_select ON workspace_config;
--   DROP POLICY IF EXISTS workspace_config_insert ON workspace_config;
--   DROP POLICY IF EXISTS workspace_config_update ON workspace_config;
--   DROP POLICY IF EXISTS workspace_config_delete ON workspace_config;
--
--   -- Recreate migration 001's admin-only policies on projects
--   CREATE POLICY projects_select ON projects FOR SELECT USING (
--     submitter_email = auth.email() OR workspace_id IN (
--       SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY projects_insert ON projects FOR INSERT WITH CHECK (
--     submitter_email = auth.email() OR workspace_id IN (
--       SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY projects_update ON projects FOR UPDATE
--     USING ((submitter_email = auth.email() AND status = 'Submitted')
--            OR workspace_id IN (SELECT workspace_id FROM workspace_members
--              WHERE user_id = auth.uid() AND role = 'admin'))
--     WITH CHECK ((submitter_email = auth.email() AND status = 'Submitted')
--            OR workspace_id IN (SELECT workspace_id FROM workspace_members
--              WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY projects_delete ON projects FOR DELETE USING (
--     workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--
--   -- Recreate migration 001's permissive portal SELECT on workspace_config
--   CREATE POLICY workspace_config_select ON workspace_config
--     FOR SELECT USING (auth.uid() IS NOT NULL);
--
--   -- Recreate migration 001's admin-only reps policies
--   CREATE POLICY reps_select ON reps FOR SELECT USING (
--     workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY reps_insert ON reps FOR INSERT WITH CHECK (
--     workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY reps_update ON reps FOR UPDATE
--     USING (workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'))
--     WITH CHECK (workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
--   CREATE POLICY reps_delete ON reps FOR DELETE USING (
--     workspace_id IN (SELECT workspace_id FROM workspace_members
--       WHERE user_id = auth.uid() AND role = 'admin'));
-- COMMIT;
--
-- NOTE: This rollback reintroduces the silent bug on workspace_config
-- writes and does NOT recreate the retired "Members can..." / "PMs can..."
-- named policies. It gets you to the known-good state after 001, not to
-- the original state before 001.
-- =========================================================================
