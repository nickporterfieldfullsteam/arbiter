import { test, expect } from '../helpers/fixtures';
import { getProjectByName } from '../helpers/supabase';
import { createProject } from '../helpers/scorecard';

/**
 * v1.9.6 regression test: Cancel button during edit, with confirmation.
 *
 * The bug: there was no way to back out of an "Edit & re-score" session
 * without either (a) saving your in-progress changes, or (b) clicking
 * the tab nav back to Dashboard — which silently retained the edit
 * state behind the scenes until the FAB was clicked. Users couldn't
 * cleanly say "never mind, I don't want to change this project."
 *
 * Fix: added a Cancel button that appears only during edit mode. It
 * shows a native confirm("Discard changes?") dialog; on confirm it
 * calls cancelEdit() (which wipes the form + resets save button
 * label) and navigates back to the tracker.
 *
 * This test verifies the full cancel path:
 *   1. Edit a project — Cancel button should appear, Clear form should hide
 *   2. Modify a field (to simulate in-progress changes)
 *   3. Click Cancel, accept the confirm dialog
 *   4. Should land on Dashboard, with no change to the underlying project
 *   5. FAB should now open an empty form (not pre-filled with old values)
 */
test.describe('v1.9.6 cancel-on-edit regression', () => {
  test('Cancel during edit discards changes after confirmation', async ({ authedPage }) => {
    // Seed a project to edit
    await createProject(authedPage, {
      name: 'Cancel-test original',
      customer: 'Beta Corp',
      submitter: 'Bob Builder',
      email: 'bob@beta.example.com',
    });

    const seed = await getProjectByName('Cancel-test original');
    expect(seed).not.toBeNull();
    const originalName = seed.name;

    // Enter edit mode
    await authedPage.locator(`#proj-row-${seed.id}`).click();
    await authedPage.locator(`#proj-detail-${seed.id}`).getByRole('button', { name: /Edit & re-score/i }).click();

    // Verify button state: Cancel visible, Clear form hidden
    await expect(authedPage.locator('#btn-cancel-edit')).toBeVisible();
    await expect(authedPage.locator('#btn-clear-form')).toBeHidden();

    // Verify form is populated with original values
    await expect(authedPage.locator('#df-__name__')).toHaveValue('Cancel-test original');

    // Make an in-progress change (this is what Cancel should discard)
    await authedPage.locator('#df-__name__').fill('About to change my mind');

    // Set up dialog handler BEFORE clicking Cancel — Playwright needs
    // the handler registered or the dialog will just auto-dismiss and
    // we won't know whether it appeared.
    let dialogMessage = '';
    authedPage.once('dialog', async dialog => {
      dialogMessage = dialog.message();
      await dialog.accept();
    });

    await authedPage.locator('#btn-cancel-edit').click();

    // The confirm dialog should have fired with the expected wording
    await expect.poll(() => dialogMessage).toContain('Discard changes');

    // After cancel: should be on the tracker tab
    await expect(authedPage.locator('#tab-tracker')).toBeVisible();
    await expect(authedPage.locator('#new-request-fab')).toBeVisible();

    // The underlying project should be UNCHANGED in Supabase (the DB
    // write for the edit would only happen on save, but this is the
    // defensive check that cancel didn't accidentally persist).
    const after = await getProjectByName(originalName);
    expect(after).not.toBeNull();
    expect(after.name).toBe(originalName);

    // The should-be-discarded typed value 'About to change my mind'
    // should not exist as a project
    const ghost = await getProjectByName('About to change my mind');
    expect(ghost).toBeNull();

    // Now click the FAB and verify the form is pristine (no leftover
    // edit-state values). This is the integration with v1.9.5's fix.
    await authedPage.locator('#new-request-fab').click();
    await expect(authedPage.locator('#tab-intake')).toBeVisible();
    await expect(authedPage.locator('#df-__name__')).toHaveValue('');
    await expect(authedPage.locator('#df-__customer__')).toHaveValue('');
    // Button state should be back to normal (Cancel hidden, Clear form visible)
    await expect(authedPage.locator('#btn-cancel-edit')).toBeHidden();
    await expect(authedPage.locator('#btn-clear-form')).toBeVisible();
  });

  test('Cancel during edit is abortable (dismiss confirm keeps you in edit mode)', async ({ authedPage }) => {
    // Set up: same flow, but when the confirm dialog appears, dismiss
    // it instead of accepting. The user should remain in edit mode
    // with their in-progress changes intact.

    await createProject(authedPage, {
      name: 'Cancel-abort test',
      customer: 'Gamma Corp',
      submitter: 'Greta Genesis',
      email: 'greta@gamma.example.com',
    });

    const seed = await getProjectByName('Cancel-abort test');
    expect(seed).not.toBeNull();

    await authedPage.locator(`#proj-row-${seed.id}`).click();
    await authedPage.locator(`#proj-detail-${seed.id}`).getByRole('button', { name: /Edit & re-score/i }).click();

    // Make an in-progress change
    await authedPage.locator('#df-__name__').fill('Half-typed new name');

    // Dismiss the confirm dialog
    authedPage.once('dialog', async dialog => {
      await dialog.dismiss();
    });

    await authedPage.locator('#btn-cancel-edit').click();

    // We should STILL be on the intake tab, with Cancel visible and
    // the in-progress value preserved.
    await expect(authedPage.locator('#tab-intake')).toBeVisible();
    await expect(authedPage.locator('#btn-cancel-edit')).toBeVisible();
    await expect(authedPage.locator('#df-__name__')).toHaveValue('Half-typed new name');
  });
});
