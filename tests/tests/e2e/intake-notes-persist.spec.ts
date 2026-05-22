import { test, expect } from '../helpers/fixtures';
import { getProjectByName, seedProjects } from '../helpers/supabase';
import { createProject } from '../helpers/scorecard';
import { reloadAndWaitForInit } from '../helpers/auth';

/**
 * Project notes persistence tests.
 *
 * Notes are stored in the project_notes table. Each note is an instant-save
 * INSERT triggered by pressing Enter in the notes textarea (Shift+Enter
 * inserts a newline).
 */
test.describe('Project notes', () => {
  test('Note added via inline panel persists to Supabase', async ({ authedPage }) => {
    await createProject(authedPage, {
      name: 'Notes persist test',
      customer: 'Test Co',
      submitter: 'Test Submitter',
      email: 'test@example.com',
    });

    const before = await getProjectByName('Notes persist test');
    expect(before).not.toBeNull();
    const projectId = before.id;

    // Navigate to Intake tab and expand the project's inline detail panel
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    // Wait for notes log to render (async load)
    const notesContainer = authedPage.locator('#notes-log-inline-' + projectId);
    await expect(notesContainer).toBeVisible();
    await expect(notesContainer.locator('textarea')).toBeVisible({ timeout: 5000 });

    // Type a note and press Enter to submit
    await notesContainer.locator('textarea').fill('Approved by leadership. Ship in Q3.');
    await notesContainer.locator('textarea').press('Enter');

    // Wait for toast confirming the note was added
    await expect(authedPage.locator('#toast')).toContainText('Note added', { timeout: 5000 });

    // The note should now appear in the notes log
    await expect(notesContainer).toContainText('Approved by leadership. Ship in Q3.');

    // Reload and verify note survives
    await reloadAndWaitForInit(authedPage);
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    const notesAfterReload = authedPage.locator('#notes-log-inline-' + projectId);
    await expect(notesAfterReload).toContainText('Approved by leadership. Ship in Q3.', { timeout: 5000 });
  });

  test('Note added via Kanban modal persists to Supabase', async ({ authedPage }) => {
    await createProject(authedPage, {
      name: 'Kanban notes test',
      customer: 'Test Co',
      submitter: 'Test Submitter',
      email: 'test@example.com',
    });

    const before = await getProjectByName('Kanban notes test');
    expect(before).not.toBeNull();
    const projectId = before.id;

    // Switch to Kanban view and open the card modal
    await authedPage.locator('#view-btn-board').click();
    await expect(authedPage.locator('.kanban-board')).toBeVisible();
    await authedPage.locator(`.kanban-card[data-id="${projectId}"]`).click();

    // Wait for notes log to render inside the modal
    const modalNotes = authedPage.locator(`#notes-log-modal-${projectId}`);
    await expect(modalNotes).toBeVisible();
    await expect(modalNotes.locator('textarea')).toBeVisible({ timeout: 5000 });

    // Type a note and press Enter to submit
    await modalNotes.locator('textarea').fill('Deferred pending Q4 budget review.');
    await modalNotes.locator('textarea').press('Enter');

    // Wait for toast
    await expect(authedPage.locator('#toast')).toContainText('Note added', { timeout: 5000 });

    // Note should appear in the modal's log
    await expect(modalNotes).toContainText('Deferred pending Q4 budget review.');
  });

  test('Note added via Active Projects panel persists to Supabase', async ({ authedPage }) => {
    // Seed an Accepted project with execution fields so it appears in Active Projects
    const seeded = await seedProjects([{
      name: 'Exec notes test',
      status: 'Accepted',
      score: 80,
      executionLifecycle: 'Development',
      executionStatus: 'On Track',
    }]);
    expect(seeded.length).toBe(1);
    const projectId = seeded[0].id;

    // Reload to pick up the seeded project
    await reloadAndWaitForInit(authedPage);

    // Navigate to Active Projects and expand the project
    await authedPage.locator('#tab-btn-active-projects').click();
    await expect(authedPage.locator('#tab-active-projects')).toBeVisible();
    await authedPage.locator(`[onclick="toggleApDetail('${projectId}')"]`).click();

    // Wait for the detail panel and notes log
    const panel = authedPage.locator('#ap-detail-' + projectId);
    await expect(panel).toBeVisible();
    const notesContainer = panel.locator('[data-notes-log]');
    await expect(notesContainer).toBeVisible();
    await expect(notesContainer.locator('textarea')).toBeVisible({ timeout: 5000 });

    // Type a note and press Enter
    await notesContainer.locator('textarea').fill('Blocked on API dependency from Platform team.');
    await notesContainer.locator('textarea').press('Enter');

    // Wait for toast
    await expect(authedPage.locator('#toast')).toContainText('Note added', { timeout: 5000 });

    // Note should appear
    await expect(notesContainer).toContainText('Blocked on API dependency from Platform team.');
  });

  test('Multiple notes appear in newest-first order', async ({ authedPage }) => {
    await createProject(authedPage, {
      name: 'Multi notes test',
      customer: 'Test Co',
      submitter: 'Test Submitter',
      email: 'test@example.com',
    });

    const before = await getProjectByName('Multi notes test');
    expect(before).not.toBeNull();
    const projectId = before.id;

    // Open the inline detail panel
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    const notesContainer = authedPage.locator('#notes-log-inline-' + projectId);
    await expect(notesContainer.locator('textarea')).toBeVisible({ timeout: 5000 });

    // Add first note
    await notesContainer.locator('textarea').fill('First note');
    await notesContainer.locator('textarea').press('Enter');
    await expect(authedPage.locator('#toast')).toContainText('Note added', { timeout: 5000 });
    await expect(notesContainer).toContainText('First note');

    // Add second note
    await notesContainer.locator('textarea').fill('Second note');
    await notesContainer.locator('textarea').press('Enter');
    await expect(authedPage.locator('#toast')).toContainText('Note added', { timeout: 5000 });
    await expect(notesContainer).toContainText('Second note');

    // Both notes present
    await expect(notesContainer).toContainText('First note');
    await expect(notesContainer).toContainText('Second note');

    // Newest first: the note cards are in a container div, second note should come before first
    const noteCards = notesContainer.locator('div[style*="border-left"]');
    const count = await noteCards.count();
    expect(count).toBe(2);
    await expect(noteCards.first()).toContainText('Second note');
    await expect(noteCards.last()).toContainText('First note');
  });

  test('Empty note is not saved (Enter on blank textarea does nothing)', async ({ authedPage }) => {
    await createProject(authedPage, {
      name: 'Empty note test',
      customer: 'Test Co',
      submitter: 'Test Submitter',
      email: 'test@example.com',
    });

    const before = await getProjectByName('Empty note test');
    expect(before).not.toBeNull();
    const projectId = before.id;

    // Open the inline detail panel
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    const notesContainer = authedPage.locator('#notes-log-inline-' + projectId);
    await expect(notesContainer.locator('textarea')).toBeVisible({ timeout: 5000 });

    // Press Enter with empty textarea
    await notesContainer.locator('textarea').press('Enter');

    // No toast should appear — wait a moment then confirm "No notes yet" still shows
    await authedPage.waitForTimeout(500);
    await expect(notesContainer).toContainText('No notes yet');

    // Try whitespace only
    await notesContainer.locator('textarea').fill('   ');
    await notesContainer.locator('textarea').press('Enter');
    await authedPage.waitForTimeout(500);
    await expect(notesContainer).toContainText('No notes yet');
  });
});
