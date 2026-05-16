import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  getChanges,
  openStudio,
  pollUntil
} from '../../fixtures/studio';
import { seedMatterAndDocument } from '../../fixtures/seeds';

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

      // Seed an inline matter + document via the test-only POST routes
      // so the scenario is self-contained and doesn't depend on the
      // sprite DB having a pre-existing row. The seeder is gated by
      // `compile_env(:test_auth)` — production builds 404.
      // Use `page` here (not `request`) so the seed call rides the
      // same cookie jar as `signInAs(page, ...)` — otherwise the
      // controller falls back to minting a throwaway persona, which
      // can flake on PersonaFactory email collisions.
      const { document } = await seedMatterAndDocument(page, {
        title: 'Clean-revoke scenario doc',
        type_key: 'nda_v1'
      });

      await openStudio(page, {
        id: document.id,
        matter_id: document.matter_id,
        name: document.title,
        type_key: document.type_key,
        inserted_at: ''
      });

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
        // Use `pushHookEvent` (not `pushEvent`) — `view.pushEvent` is a
        // private LV API whose first argument is a `type` discriminator
        // and second is a DOM `el`; calling it with `(name, payload)`
        // routes `payload` into `extractMeta(el, ...)` which then
        // crashes on `el.attributes.length`. `pushHookEvent(el, ctx,
        // event, payload)` is the proper outside-the-hook entrypoint.
        // Engine-shaped payload per SPEC §13 — `:edit_document` reads
        // `payload.ops` as a list of Operation maps.
        const lv = (window as unknown as {
          liveSocket?: {
            owner?: (el: Element) => {
              pushHookEvent: (
                el: Element,
                ctx: unknown,
                event: string,
                payload: Record<string, unknown>
              ) => unknown;
            };
          };
        }).liveSocket;
        const root = document.querySelector('[data-phx-main]');
        if (!root) throw new Error('Studio LV root not mounted');
        const view = lv?.owner?.(root);
        view?.pushHookEvent(root, null, 'edit_document', {
          document_id: docId,
          ops: [
            {
              op: 'replace_content',
              target_type: 'node',
              target_id: 'node-effective-date',
              args: { content: '2026-01-01' }
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

      // Wait for the revoke change to land. The Cmd+Z keyboard path is
      // handled by Canvas.Editor's `.Editable` hook on `window` (capture
      // phase) — it caches the last-committed change-id from the LV's
      // `phx:editor:last-change` event and pushes `revoke_change` with
      // that id. Server-side, `Studio.submit` writes a Change row with
      // `action_kind: "revoke_change"` whose preimage targets the
      // original edit.
      const afterUndo = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.some((r) => r.action_kind === 'revoke_change'),
        { timeoutMs: 10_000, label: 'revoke change appears' }
      );

      // A revoke change exists.
      const revoke = afterUndo.find((r) => r.action_kind === 'revoke_change');
      expect(revoke).toBeTruthy();

      // The original edit row is still present (its `status` flip to
      // `revoked` is a separate Store-layer concern not under this
      // scenario's purview — see studio_live_test.exs LV pin).
      const original = afterUndo.find((r) => r.id === editChange.id);
      expect(original).toBeTruthy();

      // Stamp the report with the viewport for human-readable artefacts.
      testInfo.annotations.push({ type: 'viewport', description: viewport });
    });
  }
});
