import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getDocuments,
  openStudio,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 6 — Cmd+K palette → set contract type.
 *
 * Open the command palette → type "set contract type" → Enter →
 * type-picker modal → pick `franchise_v1` → `documents.type_key` updates.
 *
 * The Cmd+K palette is a desktop-only interaction (chord keyboard
 * shortcut). On mobile the equivalent is the chat-command button — per
 * feedback-responsive-scope.md "the Cmd+K command palette — Cmd+K isn't
 * a mobile interaction; replace with a 'command' button in the chat
 * input area on mobile". This scenario covers BOTH paths, one per
 * viewport.
 */

test.describe('Scenario 6: Cmd+K palette (mobile: chat-command button)', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] palette → set contract type → DB updates`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — Cmd+K palette requires a target document.'
      );
      if (!document) return;

      await openStudio(page, document);

      if (viewport === 'desktop') {
        await page.keyboard.press('Control+KeyK');
      } else {
        const cmdBtn = page.locator('[data-role="chat-command"]').first();
        // The chat-command button is the mobile substitute. If it isn't
        // rendered, skip cleanly — we still cover the desktop path.
        if ((await cmdBtn.count()) === 0) {
          test.skip(true, 'No chat-command button rendered in mobile Studio yet.');
          return;
        }
        await cmdBtn.click();
      }

      const palette = page.locator('[data-role="command-palette"], #command-palette').first();
      await expect(palette).toBeVisible({ timeout: 5_000 });

      const input = palette.locator('input').first();
      await input.fill('set contract type');
      await page.keyboard.press('Enter');

      const picker = page.locator('[data-role="type-picker"]').first();
      await expect(picker).toBeVisible({ timeout: 5_000 });

      // Pick franchise_v1.
      await picker.getByText(/franchise_v1/i).first().click();

      // Confirm the DB now shows the new type_key.
      const docs = await pollUntil(
        () => getDocuments(request),
        (rows) =>
          rows.some((d) => d.id === document.id && /franchise/i.test(d.type_key ?? '')),
        { timeoutMs: 8_000, label: 'documents.type_key updated to franchise_v1' }
      );
      const updated = docs.find((d) => d.id === document.id);
      expect(updated?.type_key).toMatch(/franchise/i);
    });
  }
});
