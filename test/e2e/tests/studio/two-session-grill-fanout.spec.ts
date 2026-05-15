import { test, expect, chromium } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import { findOrSkipDocument, openStudio } from '../../fixtures/studio';

/**
 * Scenario 8 — two-session grill fanout (desktop only).
 *
 * Context A: `:lawyer` — opens the document, starts a grill via chat.
 * Context B: `:agent_supervised` — opens the same document; observes the
 *            grill rail receive the same ask-marks within 2s (PubSub
 *            fanout verified).
 *
 * Desktop-only because the chat-first mobile layout doesn't surface the
 * grill rail directly — it lives in the preview-modal marks tab on
 * mobile — and the brief explicitly says "two-session live grill fanout
 * makes more sense on desktop only".
 *
 * ⚠️  Real OpenAI call. Tagged `@e2e:expensive` so CI can throttle via
 * `EXPENSIVE_E2E=0`.
 */

test.describe('Scenario 8: two-session grill fanout @e2e:expensive', () => {
  test.skip(
    process.env.EXPENSIVE_E2E === '0',
    'EXPENSIVE_E2E=0 — skipping real-OpenAI scenario'
  );

  test('[desktop] lawyer grills → agent_supervised sees ask-marks within 2s', async ({
    browser,
    request
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== 'chromium-desktop',
      'two-session grill fanout is desktop-only'
    );

    await resetE2EState(request);

    // Two independent BrowserContexts so the sessions don't share cookies.
    const ctxLawyer = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const ctxSupervised = await browser.newContext({
      viewport: { width: 1440, height: 900 }
    });

    const pageLawyer = await ctxLawyer.newPage();
    const pageSupervised = await ctxSupervised.newPage();

    try {
      await signInAs(pageLawyer, 'lawyer');
      await signInAs(pageSupervised, 'agent_supervised');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — two-session grill fanout requires a shared document.'
      );
      if (!document) return;

      await openStudio(pageLawyer, document);
      await openStudio(pageSupervised, document);

      // Lawyer sends a chat message that triggers a grill.
      const chatInput = pageLawyer
        .locator('[data-role="chat-input"] textarea, textarea[name="message"]')
        .first();
      await expect(chatInput).toBeVisible();
      await chatInput.fill(
        '이 계약의 효력 발생일과 만기일을 확인해 주세요. (Please grill me on the effective date and expiry.)'
      );
      await chatInput.press('Enter');

      // Both rails should show the ask-marks. Wait for them in parallel.
      const railLawyer = pageLawyer
        .locator('[data-role="grill-rail"], #grill-rail')
        .first();
      const railSupervised = pageSupervised
        .locator('[data-role="grill-rail"], #grill-rail')
        .first();

      await expect(railLawyer).toBeVisible({ timeout: 30_000 });
      await expect(railSupervised).toBeVisible({ timeout: 30_000 });

      const lawyerAsks = railLawyer.locator('[data-mark-intent="ask"], [data-intent="ask"]');
      const supervisedAsks = railSupervised.locator(
        '[data-mark-intent="ask"], [data-intent="ask"]'
      );

      // Wait for at least one mark to show up on the lawyer's side.
      await expect(lawyerAsks.first()).toBeVisible({ timeout: 30_000 });
      const lawyerSeenAt = Date.now();

      // The supervised context must see the SAME mark within 2s of the
      // lawyer seeing it (PubSub fanout SLA).
      await expect(supervisedAsks.first()).toBeVisible({ timeout: 2_500 });
      const supervisedSeenAt = Date.now();

      expect(supervisedSeenAt - lawyerSeenAt).toBeLessThan(2_500);

      // Cardinalities should match: both contexts see the same number of
      // ask-marks.
      const lawyerCount = await lawyerAsks.count();
      const supervisedCount = await supervisedAsks.count();
      expect(supervisedCount).toBe(lawyerCount);
    } finally {
      await ctxLawyer.close();
      await ctxSupervised.close();
    }
  });
});
