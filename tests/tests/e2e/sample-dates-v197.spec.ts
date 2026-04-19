import { test, expect } from '../helpers/fixtures';
import { countProjects } from '../helpers/supabase';
import { openSettingsTab } from '../helpers/auth';
import { createClient } from '@supabase/supabase-js';

/**
 * v1.9.7 regression test: sample project created_at is backdated.
 *
 * The bug: the sample generator assigned a formatted `date` field per
 * sample (e.g. "4/14/2026" for a 30-day-old one), but sbUpsertProject
 * never sent `created_at` in the insert row. The DB defaulted to NOW()
 * for every sample, and the app reads the list date from created_at.
 * Result: every sample showed as created today, even though they were
 * supposed to span 1–110 days of history.
 *
 * Fix: sample generator now sets proj.createdAt = ISO timestamp, and
 * sbUpsertProject forwards it as row.created_at when present. Regular
 * user-created projects still omit createdAt and get DB default.
 *
 * This test generates the 13 samples, then reads created_at directly
 * from Supabase and verifies the spread is real — at least one very
 * recent sample (<=3 days old) and at least one quite old (>=60 days).
 * Those two exist deliberately in the fixture data; if the bug comes
 * back, they'll collapse to now().
 */
test.describe('v1.9.7 sample-date regression', () => {
  test('sample projects have properly backdated created_at timestamps', async ({ authedPage }) => {
    expect(await countProjects()).toBe(0);

    await openSettingsTab(authedPage);
    await authedPage.locator('#btn-generate-samples').click();

    await expect.poll(
      async () => await countProjects(),
      { timeout: 15_000, intervals: [500, 1000, 2000] }
    ).toBe(13);

    // Read all sample created_at values directly from Supabase
    const sb = createClient(
      process.env.SUPABASE_URL!,
      process.env.SUPABASE_PUBLISHABLE_KEY!
    );
    // Sign in as the test user to satisfy any RLS checks
    await sb.auth.signInWithPassword({
      email: process.env.TEST_USER_EMAIL!,
      password: process.env.TEST_USER_PASSWORD!,
    });
    const { data, error } = await sb
      .from('projects')
      .select('name, created_at')
      .eq('workspace_id', process.env.TEST_WORKSPACE_ID!)
      .eq('is_sample', true)
      .is('deleted_at', null);

    expect(error).toBeNull();
    expect(data).not.toBeNull();
    expect(data!.length).toBe(13);

    // Compute age in days for each sample relative to now
    const now = Date.now();
    const ages = data!.map(r => ({
      name: r.name,
      ageDays: (now - new Date(r.created_at).getTime()) / (1000 * 60 * 60 * 24),
    }));

    // The youngest sample should be <=3 days old (the fixture has a
    // 'daysAgo: 1' and 'daysAgo: 2' sample — allow a small buffer for
    // clock drift / test latency).
    const youngest = Math.min(...ages.map(a => a.ageDays));
    expect(youngest).toBeLessThanOrEqual(3);

    // The oldest sample should be >=60 days old (fixture has a 110-day
    // and a 90-day sample). If the bug regresses, every sample will
    // be ~0 days old and this assertion will fail.
    const oldest = Math.max(...ages.map(a => a.ageDays));
    expect(oldest).toBeGreaterThanOrEqual(60);

    // Spread (max - min) should be substantial. If every sample
    // collapsed to now(), spread would be ~0.
    const spread = oldest - youngest;
    expect(spread).toBeGreaterThanOrEqual(50);
  });
});
