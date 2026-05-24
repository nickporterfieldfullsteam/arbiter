import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import * as path from 'path';

/**
 * Portal rep notes — reps can view PM notes and add their own.
 *
 * Uses real Supabase auth (test rep account) and real DB writes to
 * verify RLS allows rep note inserts with author_role='rep' and that
 * the notes log renders both PM and rep notes.
 *
 * Setup: seeds a project as the PM, adds a PM note, then signs in as
 * the rep in the portal and interacts with the notes log.
 */

const SB_AUTH_KEY = 'sb-arbiter-portal-auth';

function getSupabaseClient() {
  return createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_PUBLISHABLE_KEY!);
}

async function getAdminClient() {
  const client = getSupabaseClient();
  const { error } = await client.auth.signInWithPassword({
    email: process.env.TEST_USER_EMAIL!,
    password: process.env.TEST_USER_PASSWORD!,
  });
  if (error) throw new Error('Admin sign-in failed: ' + error.message);
  return client;
}

async function getRepClient() {
  const url = process.env.SUPABASE_URL!;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
  const client = createClient(url, key);
  const { data, error } = await client.auth.signInWithPassword({
    email: process.env.TEST_REP_EMAIL!,
    password: process.env.TEST_REP_PASSWORD!,
  });
  if (error) throw new Error('Rep sign-in failed: ' + error.message);
  return { client, session: data.session! };
}

function getPortalURL(): string {
  const target = process.env.TEST_LIVE_URL || process.env.TEST_SERVER_URL || '';
  if (target) {
    const base = target.endsWith('/') ? target : target + '/';
    return base + 'portal/index.html';
  }
  const absPath = path.resolve(__dirname, '..', '..', '..', 'portal', 'index.html');
  return 'file://' + absPath.split(path.sep).join('/');
}

test.describe('Portal rep notes', () => {
  const workspaceId = process.env.TEST_WORKSPACE_ID!;
  const repEmail = process.env.TEST_REP_EMAIL!;
  let seededProjectId: string;
  let repSessionData: any;

  test.beforeAll(async () => {
    const admin = await getAdminClient();

    // Clean workspace
    await admin.from('projects').delete().eq('workspace_id', workspaceId);

    // Seed a project submitted by the test rep
    const { data: project, error: projErr } = await admin.from('projects').insert({
      workspace_id: workspaceId,
      name: 'Rep notes test project',
      status: 'Submitted',
      score: 50,
      tier: 'evaluate',
      criteria_vals: {},
      criteria_snapshot: {},
      locked_vals: { __name__: 'Rep notes test', __customer__: 'Test Co', __submitter__: 'Test Rep', __email__: repEmail },
      detail_vals: {},
      project_type: '',
      is_sample: false,
      submitter_email: repEmail,
    }).select().single();
    if (projErr) throw new Error('Seed project failed: ' + projErr.message);
    seededProjectId = project.id;

    // Add a PM note on this project
    await admin.from('project_notes').insert({
      project_id: seededProjectId,
      workspace_id: workspaceId,
      author_name: 'Nick Porterfield',
      author_email: process.env.TEST_USER_EMAIL!,
      author_role: 'pm',
      body: 'Can you provide more context on the timeline?',
    });

    // Get a real rep session for seeding into the portal
    const { session } = await getRepClient();
    repSessionData = {
      access_token: session.access_token,
      token_type: 'bearer',
      expires_in: session.expires_in,
      expires_at: session.expires_at,
      refresh_token: session.refresh_token,
      user: session.user,
    };
  });

  test.afterAll(async () => {
    const admin = await getAdminClient();
    await admin.from('project_notes').delete().eq('project_id', seededProjectId);
    await admin.from('projects').delete().eq('workspace_id', workspaceId);
  });

  test('Rep can see PM notes in the portal detail panel', async ({ page }) => {
    const url = getPortalURL();

    // Seed the real rep session and override workspace ID before page loads
    await page.addInitScript(
      ({ key, session, wsId }) => {
        localStorage.setItem(key, JSON.stringify(session));
        (window as any).__TEST_WORKSPACE_ID__ = wsId;
      },
      { key: SB_AUTH_KEY, session: repSessionData, wsId: workspaceId }
    );

    await page.goto(url);
    await expect(page.locator('#view-signed-in')).toBeVisible({ timeout: 10_000 });

    // Wait for the project to appear
    await expect(page.locator(`#proj-row-${seededProjectId}`)).toBeVisible({ timeout: 5_000 });

    // Expand the detail panel
    await page.locator(`#proj-row-${seededProjectId}`).click();
    const panel = page.locator(`#proj-detail-${seededProjectId}`);
    await expect(panel).toHaveClass(/open/);

    // PM note should be visible
    const notesContainer = panel.locator(`#portal-notes-${seededProjectId}`);
    await expect(notesContainer).toContainText('Can you provide more context on the timeline?', { timeout: 5_000 });
    // PM badge should be visible
    await expect(notesContainer).toContainText('PM');
  });

  test('Rep can add a note that persists to Supabase', async ({ page }) => {
    const url = getPortalURL();

    await page.addInitScript(
      ({ key, session, wsId }) => {
        localStorage.setItem(key, JSON.stringify(session));
        (window as any).__TEST_WORKSPACE_ID__ = wsId;
      },
      { key: SB_AUTH_KEY, session: repSessionData, wsId: workspaceId }
    );
    await page.goto(url);
    await expect(page.locator('#view-signed-in')).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(`#proj-row-${seededProjectId}`)).toBeVisible({ timeout: 5_000 });

    // Expand and wait for notes to load
    await page.locator(`#proj-row-${seededProjectId}`).click();
    const notesContainer = page.locator(`#portal-notes-${seededProjectId}`);
    await expect(notesContainer.locator('textarea')).toBeVisible({ timeout: 5_000 });

    // Type a note and press Enter
    await notesContainer.locator('textarea').fill('Timeline is Q4 2026. We need it before renewal.');
    await notesContainer.locator('textarea').press('Enter');

    // Toast should confirm
    await expect(page.locator('#toast')).toContainText('Note added', { timeout: 5_000 });

    // Note should appear in the log
    await expect(notesContainer).toContainText('Timeline is Q4 2026. We need it before renewal.');

    // Verify in DB that the note has author_role='rep'
    const { client: repClient } = await getRepClient();
    const { data: notes } = await repClient.from('project_notes')
      .select('author_name,author_role,body')
      .eq('project_id', seededProjectId)
      .eq('author_role', 'rep');
    expect(notes).not.toBeNull();
    expect(notes!.length).toBeGreaterThanOrEqual(1);
    const repNote = notes!.find(n => n.body.includes('Timeline is Q4 2026'));
    expect(repNote).toBeDefined();
    expect(repNote!.author_role).toBe('rep');
  });

  test('Both PM and rep notes appear in correct order (newest first)', async ({ page }) => {
    const url = getPortalURL();

    await page.addInitScript(
      ({ key, session, wsId }) => {
        localStorage.setItem(key, JSON.stringify(session));
        (window as any).__TEST_WORKSPACE_ID__ = wsId;
      },
      { key: SB_AUTH_KEY, session: repSessionData, wsId: workspaceId }
    );
    await page.goto(url);
    await expect(page.locator('#view-signed-in')).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(`#proj-row-${seededProjectId}`)).toBeVisible({ timeout: 5_000 });

    await page.locator(`#proj-row-${seededProjectId}`).click();
    const notesContainer = page.locator(`#portal-notes-${seededProjectId}`);
    await expect(notesContainer).toContainText('Can you provide more context', { timeout: 5_000 });

    // Both PM and rep notes should be present
    await expect(notesContainer).toContainText('Can you provide more context on the timeline?');
    await expect(notesContainer).toContainText('Timeline is Q4 2026');

    // Rep note (newer) should come before PM note (older)
    const noteCards = notesContainer.locator('div[style*="border-left"]');
    const count = await noteCards.count();
    expect(count).toBeGreaterThanOrEqual(2);
    await expect(noteCards.first()).toContainText('Timeline is Q4 2026');
    await expect(noteCards.last()).toContainText('Can you provide more context');
  });
});
