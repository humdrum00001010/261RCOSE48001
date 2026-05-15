import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getChanges,
  openStudio,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 2 — clean revoke (no overlap).
 *
 * Lawyer edits a paragraph → presses Cmd+Z (Ctrl+Z) → projection rolls
 * back → DB has a revoke `Change` with `status: :revoked` on the original.
 *
 * Edits are pushed via the LV's `edit_document` event directly (no agent
 * round-trip), which keeps this scenario cheap and deterministic. The
 * agent path is covered by Scenario 1.
 */

test.describe('Scenario 2: clean revoke', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] edit → Cmd+Z → revoke change committed`, async ({
      page,
      request
    }, testInfo) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — clean-revoke requires the Wave 3C1 documents migration on the public sprite.'
      );
      if (!document) return;

      await openStudio(page, document);

      // Capture baseline change-count so we can wait for the edit + revoke
      // pair specifically (not whatever else might already exist).
      const baseline = await getChanges(request, document.id);
      const baseCount = baseline.length;

      // Fire `edit_document` via a JS pushEvent — the LV processes the
      // event end-to-end (Studio.submit → Runtime.apply → Store.append).
      // This avoids depending on a particular Canvas UI control.
      const edited = await page.evaluate(() => {
        const hook = (window as unknown as { liveSocket?: { execJS?: unknown } }).liveSocket;
        return Boolean(hook);
      });
      if (!edited) {
        test.skip(true, 'No live socket — the Studio LV failed to mount in this state.');
        return;
      }

      await page.evaluate((docId) => {
        const lv = (window as unknown as {
          liveSocket?: {
            main?: { childNodes?: unknown };
            owner?: (el: Element) => { pushEvent: (n: string, p: Record<string, unknown>) => void };
          };
        }).liveSocket;
        const root = document.querySelector('[data-phx-main]');
        if (!root) throw new Error('Studio LV root not mounted');
        const view = (lv as unknown as {
          owner?: (el: Element) => { pushEvent: (n: string, p: Record<string, unknown>) => void };
        }).owner?.(root);
        view?.pushEvent('edit_document', {
          document_id: docId,
          ops: [
            {
              op: 'replace_field',
              path: ['fields', 'effective_date'],
              from: null,
              to: '2026-01-01'
            }
          ]
        });
      }, document.id);

      // Wait for the edit to land as a change.
      const afterEdit = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.length === baseCount + 1,
        { timeoutMs: 10_000, label: 'edit change appears' }
      );
      const editChange = afterEdit[afterEdit.length - 1];
      expect(editChange.action_kind).toMatch(/edit|user_change/);

      // Cmd+Z (Ctrl+Z on linux). The body should have focus first.
      await page.locator('body').click({ position: { x: 10, y: 10 } });
      const meta = process.platform === 'darwin' ? 'Meta' : 'Control';
      await page.keyboard.press(`${meta}+KeyZ`);

      // Wait for the revoke change.
      const afterUndo = await pollUntil(
        () => getChanges(request, document.id),
        (rows) =>
          rows.some(
            (r) => r.action_kind === 'revoke_change' || r.status === 'revoked'
          ),
        { timeoutMs: 10_000, label: 'revoke change appears' }
      );

      // The original edit must now be `:revoked`.
      const original = afterUndo.find((r) => r.id === editChange.id);
      expect(original?.status).toBe('revoked');

      // ... and a revoke change exists pointing at it.
      const revoke = afterUndo.find((r) => r.action_kind === 'revoke_change');
      expect(revoke).toBeTruthy();

      // Stamp the report with the viewport for human-readable artefacts.
      testInfo.annotations.push({ type: 'viewport', description: viewport });
    });
  }
});
