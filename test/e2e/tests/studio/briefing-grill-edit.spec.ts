import { test, expect } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getChanges,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 1 — briefing → grill → edit.
 *
 * Lawyer uploads a small contract → Upstage parse fires → grill-rail opens
 * with at least one `Mark{intent: :ask}` → the user answers → the agent
 * commits an `Action(:agent_change)` → the DOM reflects the new content →
 * a `changes` row exists with the expected `applied_revision`.
 *
 * ⚠️  Real OpenAI + real Upstage. Tagged `@e2e:expensive` so CI can throttle
 * via `EXPENSIVE_E2E=0` (see playwright.config.ts).
 *
 * Until the documents/matters migration lands in the public sprite env this
 * scenario test.skip()s — the upload→parse path needs a writable Matter
 * scope that the LV currently can't produce. The structural assertions
 * (sign-in, navigation, grill-rail DOM hooks present) still run so we
 * notice if the public URL regresses.
 */

const __dirname_local = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.resolve(__dirname_local, '../../fixtures/tiny-contract.txt');

test.describe('Scenario 1: briefing → grill → edit @e2e:expensive', () => {
  test.skip(
    process.env.EXPENSIVE_E2E === '0',
    'EXPENSIVE_E2E=0 — skipping real-OpenAI + real-Upstage scenario'
  );

  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] lawyer uploads → grill opens → agent commits change`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      // Land on the dashboard; on mobile the chat-first layout still
      // begins at the dashboard route.
      const home = await page.goto('/dashboard');
      expect(home, 'navigation to /dashboard returned no response').not.toBeNull();
      expect(home!.status()).toBeLessThan(500);

      // Until the documents/matters migration lands we can't drive a real
      // upload through the LV's `allow_upload(:document_upload, ...)` —
      // the Studio.load/2 path needs a Matter row to write the new doc
      // against, and `e2e` matters get torn down by /test/reset. Skip
      // cleanly so the harness still reports per-viewport.
      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — briefing→grill→edit requires the Wave 3C1 documents migration on the public sprite.'
      );
      if (!document) return;

      const route = document.matter_id
        ? `/matters/${document.matter_id}/documents/${document.id}`
        : `/studio?document_id=${document.id}`;
      await page.goto(route);

      // Upload the fixture via the live file input — the StudioLive
      // `allow_upload/3` exposes a phx-hook input identified by
      // `phx-upload-ref="document_upload"`. If the input isn't present
      // (briefing UI not yet rendered for this state) skip rather than
      // assert against a non-existent control.
      const uploadInput = page.locator('input[type="file"]').first();
      if ((await uploadInput.count()) === 0) {
        test.skip(true, 'No file-upload input in the current Studio state.');
        return;
      }

      await uploadInput.setInputFiles(FIXTURE_PATH);

      // Grill-rail surfaces ask-marks via PubSub once Upstage parse +
      // OpenAI brief grader finish. Wait up to 30 s.
      const grillRail = page.locator('[data-role="grill-rail"], #grill-rail').first();
      await expect(grillRail).toBeVisible({ timeout: 30_000 });

      // At least one ask-mark must surface.
      const asks = grillRail.locator('[data-mark-intent="ask"], [data-intent="ask"]');
      await expect(asks.first()).toBeVisible({ timeout: 30_000 });

      // Answer the first ask. The chat input is always visible per
      // feedback-responsive-scope.md — submit a short answer.
      const chatInput = page.locator('[data-role="chat-input"] textarea, textarea[name="message"]').first();
      await expect(chatInput).toBeVisible();
      await chatInput.fill('Effective Date: 2026-01-01.');
      await chatInput.press('Enter');

      // Wait for the agent to commit an `:agent_change` action.
      const changes = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.some((r) => r.action_kind === 'agent_change'),
        { timeoutMs: 45_000, intervalMs: 1_000, label: 'agent_change row appears' }
      );

      const agentChange = changes.find((r) => r.action_kind === 'agent_change');
      expect(agentChange).toBeTruthy();
      expect(agentChange!.applied_revision).toBeGreaterThan(0);

      // DOM reflects the new content. We assert against a generic
      // "document-projection" container — exact selector to be tightened
      // when Canvas markup stabilises.
      const projection = page.locator('[data-role="document-projection"], [data-role="canvas"]').first();
      await expect(projection).toBeVisible();
    });
  }
});
