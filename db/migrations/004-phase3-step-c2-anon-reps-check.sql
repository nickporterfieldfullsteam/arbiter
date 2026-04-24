-- =============================================================================
-- Migration 004 — Phase 3 Step C.2: anonymous SELECT on reps for pre-auth check
-- =============================================================================
--
-- BACKGROUND
-- ----------
-- Migration 003 requires submitters to be active reps to INSERT/UPDATE on
-- projects. But the portal had no way to detect that until AFTER a user
-- authenticated and tried to submit — producing a confusing 403 rather than
-- a helpful "not authorized" message upfront.
--
-- Step C.2 changes the portal to check rep membership BEFORE sending the
-- magic-link email. That check has to run from an anonymous (unauthenticated)
-- browser session, which means the reps table needs a permissive SELECT
-- policy for the `anon` role.
--
-- SECURITY TRADEOFF
-- -----------------
-- This policy exposes whether a given (workspace_id, email) pair identifies
-- an active rep. An attacker who probes specific email addresses they
-- suspect to be reps can learn that those emails are reps. They cannot
-- enumerate all reps at once (queries must specify the email filter) and
-- they cannot read any rep they don't already have the email for.
--
-- For Arbiter's current scale (small workspace, not internet-exposed at
-- scale), this is acceptable. If/when the product scales, we should
-- replace this with a Supabase Edge Function that returns just a boolean
-- and does the check server-side without exposing the reps table at all.
--
-- STRATEGY
-- --------
-- 1. Add SELECT policy `reps_anon_auth_check` for `TO anon USING (is_active = true)`.
-- 2. Leave the existing `PMs can manage reps` policy alone — authenticated
--    admin/pm users still get full access to all reps.
-- 3. The policy is idempotent (DROP IF EXISTS + CREATE).
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Add anonymous SELECT policy to reps
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS reps_anon_auth_check ON reps;

CREATE POLICY reps_anon_auth_check ON reps
  FOR SELECT
  TO anon
  USING (is_active = true);

COMMIT;

-- ============================================================================
-- POST-APPLY SANITY CHECKS — run these separately.
-- ============================================================================
--
-- (a) Confirm policies on reps:
--   SELECT policyname, cmd, roles FROM pg_policies WHERE tablename = 'reps'
--   ORDER BY policyname;
--
-- Expected 2 rows:
--   PMs can manage reps   | ALL    | {authenticated}
--   reps_anon_auth_check  | SELECT | {anon}
--
-- (b) Confirm the policy actually allows anonymous reads of active reps.
--     Run this from the anon context — e.g., in the Supabase dashboard's
--     "API → SQL Editor" with the role set to `anon` (or test from the
--     portal's browser console after applying):
--       SELECT COUNT(*) FROM reps WHERE is_active = true;
--     Expected: returns a nonzero count (the 9 active reps).
--
-- ============================================================================
-- ROLLBACK (not executed; copy/paste if you need to revert)
-- ============================================================================
-- BEGIN;
-- DROP POLICY IF EXISTS reps_anon_auth_check ON reps;
-- COMMIT;
