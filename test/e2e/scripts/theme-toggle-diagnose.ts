/**
 * Theme toggle diagnostic — does the toggle actually work in a real
 * Chromium session against the deployed sprite?
 *
 * Steps:
 *   1. Open /
 *   2. Capture initial <html data-theme>
 *   3. Click the studio-dark button
 *   4. Wait 200ms
 *   5. Re-read <html data-theme>
 *   6. Read localStorage["phx:theme"]
 *   7. Reload
 *   8. Re-read <html data-theme>
 *   9. Print everything
 *
 *   sprite x -s contract-studio -- bash -lc 'cd ~/work/contract/test/e2e && pnpm tsx scripts/theme-toggle-diagnose.ts'
 */
import { chromium, type Browser } from '@playwright/test';

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

async function run(): Promise<void> {
  const browser: Browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    baseURL: BASE_URL,
    viewport: { width: 1280, height: 800 }
  });
  const page = await context.newPage();

  // 1. Open landing.
  await page.goto(`${BASE_URL}/`, { waitUntil: 'networkidle', timeout: 30_000 });

  // 2. Initial <html data-theme>.
  const initialTheme = await page.evaluate(() =>
    document.documentElement.getAttribute('data-theme')
  );
  const initialStorage = await page.evaluate(() =>
    localStorage.getItem('phx:theme')
  );
  console.log(`[1] initial data-theme=${JSON.stringify(initialTheme)}`);
  console.log(`[1] initial localStorage["phx:theme"]=${JSON.stringify(initialStorage)}`);

  // Diagnostic — does the button exist?
  const btnCount = await page.locator('[data-phx-theme="studio-dark"]').count();
  console.log(`[2] button count [data-phx-theme="studio-dark"]=${btnCount}`);

  if (btnCount === 0) {
    const allButtons = await page.evaluate(() => {
      const nodes = document.querySelectorAll('button');
      return Array.from(nodes).map((b) => ({
        text: b.textContent?.trim().slice(0, 40),
        aria: b.getAttribute('aria-label'),
        data: Object.fromEntries(
          Object.entries((b as HTMLElement).dataset)
        )
      }));
    });
    console.log('[2b] all buttons on page:', JSON.stringify(allButtons, null, 2));
  }

  // 3. Click studio-dark.
  await page.click('[data-phx-theme="studio-dark"]');

  // 4. Wait 200ms.
  await page.waitForTimeout(200);

  // 5. Re-read.
  const afterClickTheme = await page.evaluate(() =>
    document.documentElement.getAttribute('data-theme')
  );
  const afterClickStorage = await page.evaluate(() =>
    localStorage.getItem('phx:theme')
  );
  console.log(`[3] after-click data-theme=${JSON.stringify(afterClickTheme)}`);
  console.log(`[3] after-click localStorage["phx:theme"]=${JSON.stringify(afterClickStorage)}`);

  // 6. Reload.
  await page.reload({ waitUntil: 'networkidle' });
  const afterReloadTheme = await page.evaluate(() =>
    document.documentElement.getAttribute('data-theme')
  );
  const afterReloadStorage = await page.evaluate(() =>
    localStorage.getItem('phx:theme')
  );
  console.log(`[4] after-reload data-theme=${JSON.stringify(afterReloadTheme)}`);
  console.log(`[4] after-reload localStorage["phx:theme"]=${JSON.stringify(afterReloadStorage)}`);

  // Now check the light button.
  await page.click('[data-phx-theme="studio"]');
  await page.waitForTimeout(200);
  const afterLight = await page.evaluate(() =>
    document.documentElement.getAttribute('data-theme')
  );
  console.log(`[5] after-light-click data-theme=${JSON.stringify(afterLight)}`);

  // And system.
  await page.click('[data-phx-theme="system"]');
  await page.waitForTimeout(200);
  const afterSystem = await page.evaluate(() =>
    document.documentElement.getAttribute('data-theme')
  );
  const afterSystemStorage = await page.evaluate(() =>
    localStorage.getItem('phx:theme')
  );
  console.log(`[6] after-system-click data-theme=${JSON.stringify(afterSystem)}`);
  console.log(`[6] after-system localStorage["phx:theme"]=${JSON.stringify(afterSystemStorage)}`);

  await browser.close();
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
