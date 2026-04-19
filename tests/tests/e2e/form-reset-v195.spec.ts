import { test, expect } from '../helpers/fixtures';
import { getProjectByName } from '../helpers/supabase';
import { createProject } from '../helpers/scorecard';

/**
 * v1.9.5 regression test: form reset after editing.
 *
 * The bug: after clicking "Edit & re-score" on a project, the intake tab
 * is populated with that project's values. Clicking the floating "+"
 * button (New request) showed the intake tab again but did NOT wipe
 * those pre-filled values — the user could accidentally inherit the
 * previous project's customer/submitter/email into a brand new request.
 *
 * Fix: showNewRequest() now resets form state inline AFTER the tab is
 * made visible. Placed after tab activation so that any unexpected error
 * in the reset logic (bad DOM state, missing element, etc.) cannot
 * prevent the tab from being shown. Wrapped in try/catch as belt &
 * suspenders — reset is best-effort; showing the tab is not.
 *
 * An earlier attempt called the existing clearForm() as the first line
 * of showNewRequest(). That turned out to break all FAB-based tests —
 * if clearForm threw for any reason the tab never became visible. The
 * current fix trades a tiny amount of duplication for a guarantee that
 * tab visibility is independent of reset success.
 */
test.describe('v1.9.5 form-reset regression', () => {
  test('new request after editing starts with an empty form', async ({ authedPage }) => {
    // Seed a project we'll edit
    await createProject(authedPage, {
      name: 'Original project',
      customer: 'Alpha Corp',
      submitter: 'Alice Analyst',
      email: 'alice@alpha.example.com',
    });

    const seed = await getProjectByName('Original project');
    expect(seed).not.toBeNull();

    // Expand the project row; the detail panel (which contains the Edit
    // button) is a sibling of the row, not a child, so we scope the
    // button lookup to #proj-detail-<id>, not #proj-row-<id>.
    await authedPage.locator(`#proj-row-${seed.id}`).click();
    await authedPage.locator(`#proj-detail-${seed.id}`).getByRole('button', { name: /Edit & re-score/i }).click();

    // The intake tab should now be visible and pre-populated
    await expect(authedPage.locator('#tab-intake')).toBeVisible();
    await expect(authedPage.locator('#df-__name__')).toHaveValue('Original project');
    await expect(authedPage.locator('#df-__customer__')).toHaveValue('Alpha Corp');

    // Back to the dashboard. The Edit & re-score flow routes through
    // showTab('intake'), which hides the FAB (you're already on a
    // new-request screen) but does NOT add the "← Back to Dashboard"
    // button — that's only injected by the FAB's showNewRequest() flow.
    // So we click the Dashboard tab in the main nav to get back.
    // This is still the real user path: after editing, go back to
    // Dashboard, then hit "+" for a new request.
    await authedPage.locator('#tab-btn-tracker').click();
    await expect(authedPage.locator('#new-request-fab')).toBeVisible();

    // Click the "+" FAB to start a new request. Before the fix, this
    // left all the previous values in place. With the fix, the form
    // resets to empty after the tab is shown.
    await authedPage.locator('#new-request-fab').click();

    // Intake tab is still showing, but the fields should now all be empty.
    await expect(authedPage.locator('#tab-intake')).toBeVisible();
    await expect(authedPage.locator('#df-__name__')).toHaveValue('');
    await expect(authedPage.locator('#df-__customer__')).toHaveValue('');
    await expect(authedPage.locator('#df-__submitter__')).toHaveValue('');
    await expect(authedPage.locator('#df-__email__')).toHaveValue('');

    // The save button should be back to "Save project" (not "Update project"),
    // confirming edit-state teardown completed.
    const saveBtn = authedPage.locator('#btn-save-project');
    await expect(saveBtn).toHaveText(/Save project/i);
  });
});
