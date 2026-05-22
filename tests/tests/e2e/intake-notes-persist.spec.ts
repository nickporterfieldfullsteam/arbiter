import { test, expect } from '../helpers/fixtures';
import { getProjectByName } from '../helpers/supabase';
import { createProject } from '../helpers/scorecard';
import { reloadAndWaitForInit } from '../helpers/auth';

/**
 * Intake notes persistence test.
 *
 * Regression coverage for a bug where typing into the notes textarea and
 * clicking Save did nothing — the textarea used `onchange` which only fires
 * on blur, so clicking Save directly never captured the draft value.
 * Fixed by switching to `oninput`.
 *
 * This test verifies:
 *   1. Typing notes alone (no status change) enables the Save button.
 *   2. Clicking Save persists the notes to Supabase.
 *   3. After reload, the notes are still present in the DB and in the UI.
 */
test.describe('Intake notes persistence', () => {
  test('Notes-only change persists to Supabase without a status change', async ({ authedPage }) => {
    // Create a project via the scorecard form
    await createProject(authedPage, {
      name: 'Notes persist test',
      customer: 'Test Co',
      submitter: 'Test Submitter',
      email: 'test@example.com',
    });

    // Confirm clean initial state
    const before = await getProjectByName('Notes persist test');
    expect(before).not.toBeNull();
    expect(before.decision_notes).toBeFalsy();

    const projectId = before.id;

    // Navigate to Intake tab and expand the project's inline detail panel
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    // Type into the notes textarea (inside the inline detail panel)
    const notesTextarea = authedPage.locator(
      `#proj-detail-${projectId} textarea`
    ).first();
    await expect(notesTextarea).toBeVisible();
    await notesTextarea.fill('Approved by leadership. Ship in Q3.');

    // Save button should be enabled (draft is dirty from notes alone)
    const saveBtn = authedPage.locator(
      `button[data-draft-save="${projectId}"]`
    ).first();
    await expect(saveBtn).toBeEnabled();
    await saveBtn.click();

    // Allow the async sbUpdateProjectField call to complete
    await authedPage.waitForTimeout(500);

    // Verify DB has the notes
    const after = await getProjectByName('Notes persist test');
    expect(after).not.toBeNull();
    expect(after.decision_notes).toBe('Approved by leadership. Ship in Q3.');
    // Status should be unchanged
    expect(after.status).toBe('Submitted');

    // Reload and verify notes survive
    await reloadAndWaitForInit(authedPage);
    await authedPage.locator('#tab-btn-tracker').click();
    await authedPage.locator('#proj-row-' + projectId).click();
    await expect(authedPage.locator('#proj-detail-' + projectId)).toBeVisible();

    const notesAfterReload = authedPage.locator(
      `#proj-detail-${projectId} textarea`
    ).first();
    await expect(notesAfterReload).toHaveValue('Approved by leadership. Ship in Q3.');
  });

  test('Notes change via Kanban modal persists to Supabase', async ({ authedPage }) => {
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

    // Type into the notes textarea inside the modal
    const modalNotes = authedPage.locator(`.modal-overlay textarea`).first();
    await expect(modalNotes).toBeVisible();
    await modalNotes.fill('Deferred pending Q4 budget review.');

    // Save via the modal's Save button
    const modalSave = authedPage.locator(
      `.modal-overlay button[data-draft-save="${projectId}"]`
    );
    await expect(modalSave).toBeEnabled();
    await modalSave.click();

    await authedPage.waitForTimeout(500);

    // Verify DB
    const after = await getProjectByName('Kanban notes test');
    expect(after).not.toBeNull();
    expect(after.decision_notes).toBe('Deferred pending Q4 budget review.');
    expect(after.status).toBe('Submitted');
  });
});
