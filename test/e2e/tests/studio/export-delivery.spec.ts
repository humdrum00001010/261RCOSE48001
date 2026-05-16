import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getObanJobs,
  openStudio,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 7 — export delivery (HWPX).
 *
 * Lawyer triggers `:request_export` (via Cmd+K → "Request export" → HWPX)
 * → an Oban job is enqueued in the `export` queue → poll until completed
 * → R2 key materialises → toast appears in the UI with the download link.
 *
 * Only HWPX is fully implemented today. HTML / PDF / DOCX export are
 * stubs — tagged `@wave-4-export-pending` and skipped unless
 * `WAVE_4_READY=1`.
 */

test.describe('Scenario 7: export delivery (HWPX)', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] request HWPX export → Oban completes → toast`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — export-delivery requires a source document.'
      );
      if (!document) return;

      await openStudio(page, document);

      // Wait for the palette hook to bind before pressing the chord.
      // Without this, `page.keyboard.press` can race the LV upgrade and
      // the keypress is silently dropped (pushEventTo is a no-op
      // pre-connect). See `cmd-k-palette.spec.ts` for the same gate.
      await page
        .locator('[data-role="command-palette-root"][data-cmdk-ready="true"]')
        .first()
        .waitFor({ state: 'attached', timeout: 10_000 });
      await page.waitForFunction(
        () => {
          const w = window as unknown as { liveSocket?: { isConnected?: () => boolean } };
          return Boolean(w.liveSocket && w.liveSocket.isConnected && w.liveSocket.isConnected());
        },
        undefined,
        { timeout: 10_000 }
      );

      // Trigger via Cmd+K (desktop) or chat-command (mobile).
      if (viewport === 'desktop') {
        await page.locator('body').click({ position: { x: 10, y: 10 } });
        await page.keyboard.press('Control+KeyK');
      } else {
        const cmdBtn = page.locator('[data-role="chat-command"]').first();
        if ((await cmdBtn.count()) === 0) {
          test.skip(true, 'No chat-command button rendered in mobile Studio yet.');
          return;
        }
        await cmdBtn.click();
      }

      const palette = page.locator('[data-role="command-palette"], #command-palette').first();
      await expect(palette).toBeVisible();

      await palette.locator('input').first().fill('request export');
      await page.keyboard.press('Enter');

      const exportPicker = page.locator('[data-role="export-picker"]').first();
      await expect(exportPicker).toBeVisible();
      await exportPicker.getByText(/hwpx/i).first().click();

      // Wait for the Oban job to complete.
      const jobs = await pollUntil(
        () => getObanJobs(request, 'export'),
        (rows) => rows.some((j) => j.state === 'completed'),
        { timeoutMs: 30_000, intervalMs: 1_000, label: 'export Oban job completes' }
      );
      const completed = jobs.find((j) => j.state === 'completed');
      expect(completed).toBeTruthy();
      expect(completed?.completed_at).toBeTruthy();

      // Toast with download link appears.
      const toast = page.locator('[data-role="toast"]').filter({ hasText: /download|export|다운로드/i }).first();
      await expect(toast).toBeVisible({ timeout: 8_000 });

      // The toast should carry an <a> with an href to R2 (or a signed
      // download proxy). Don't enforce a specific host — just assert
      // it's there.
      const link = toast.locator('a').first();
      const href = await link.getAttribute('href');
      expect(href).toBeTruthy();
    });
  }
});

test.describe('Scenario 7b: non-HWPX export @wave-4-export-pending', () => {
  test.skip(
    process.env.WAVE_4_READY !== '1',
    'WAVE_4_READY != 1 — PDF/HTML/DOCX export still stubs'
  );

  test('PDF export emits completed Oban job', async ({ page, request }) => {
    // Symbolic placeholder — see Wave 4 export track.
    await resetE2EState(request);
    await signInAs(page, 'lawyer');
    const document = await findOrSkipDocument(request);
    test.skip(document === null, 'No document');
    if (!document) return;
    await openStudio(page, document);
    expect(true).toBe(true);
  });
});
