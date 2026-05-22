import { test, expect } from '../helpers/fixtures';
import { getProjectByName } from '../helpers/supabase';
import { createProject } from '../helpers/scorecard';
import { reloadAndWaitForInit } from '../helpers/auth';

/**
 * Intake notes persistence test.
 *
 * Notes are stored in the project_notes table. Each note is an instant-save
 * INSERT triggered by pressing Enter in the notes textarea (Shift+Enter
 * inserts a newline).
 *
 * This test verifies:
 *   1. Pressing Enter in the notes input persists to project_notes.
 *   2. After reload, the note appears in the notes log.
 *   3. The same flow works from the Kanban modal.
 */
test.describe('Intake notes persistence', () => {
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
});
