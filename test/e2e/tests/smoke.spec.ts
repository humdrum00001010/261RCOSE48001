import { test, expect } from '@playwright/test';
import { PERSONAS, signInAs } from '../fixtures/personas';

/**
 * Persona smoke: every canonical persona can sign in via the test-auth
 * endpoint and reach the home page over the public sprite URL. This is
 * the *connectivity* bar — it proves
 *
 *   real browser -> public DNS -> sprite proxy -> Phoenix -> Postgres
 *
 * end-to-end. Studio-specific scenarios (briefing→grill→edit, clean
 * socket reconnect, Cmd+K palette, agent_supervised watcher ship with
 * Wave 3C1 — see feedback-browser-persona-tests.md.
 */
for (const persona of PERSONAS) {
  test(`smoke: ${persona} can reach the app via the public URL`, async ({ page }) => {
    const session = await signInAs(page, persona);
    expect(session.user_id).toBeTruthy();
    expect(session.email).toContain('@example.com');

    const response = await page.goto('/');
    // The home page may redirect (302) to /users/log-in for unauth users;
    // since we signed in, expect 200 with a real body.
    expect(response, 'page.goto returned no response').not.toBeNull();
    expect(response!.status()).toBeLessThan(400);

    await expect(page.locator('body')).toBeVisible();

    // Assert the URL is still on the public sprite host (no off-host redirect).
    const url = new URL(page.url());
    expect(url.host).toBe('contract-studio-v7zk.sprites.app');
  });
}
