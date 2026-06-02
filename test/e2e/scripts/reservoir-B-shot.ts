import { chromium } from '@playwright/test';

const BASE_URL = 'https://ecrits-studio-v7zk.sprites.app';
const OUT_DIR = '/home/sprite/work/ecrits/docs/reservoir-B/2026-05-16';

async function main() {
  await import('node:fs/promises').then((fs) => fs.mkdir(OUT_DIR, { recursive: true }));

  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();

  let signedIn = false;
  for (let i = 0; i < 8; i++) {
    const resp = await context.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`);
    if (resp.status() === 200 || resp.status() === 302) {
      signedIn = true;
      break;
    }
    console.log(`sign-in attempt ${i + 1} got ${resp.status()}`);
  }
  if (!signedIn) throw new Error('persona sign-in failed');

  // Empty-state /studio — no doc selected.
  await page.goto(`${BASE_URL}/studio`);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `${OUT_DIR}/studio-empty-desktop.png`, fullPage: true });
  console.log('OK: studio-empty-desktop.png');

  // Try to find a recent document via the dashboard, then open it.
  const dashboardResp = await page.goto(`${BASE_URL}/dashboard`);
  if (dashboardResp && dashboardResp.ok()) {
    await page.waitForLoadState('networkidle');
    const docLink = page.locator('a[href*="/documents/"]').first();
    if (await docLink.count()) {
      const href = await docLink.getAttribute('href');
      if (href) {
        await page.goto(`${BASE_URL}${href}`);
        await page.waitForLoadState('networkidle');
        await page.screenshot({
          path: `${OUT_DIR}/studio-with-reservoir-desktop.png`,
          fullPage: true,
        });
        console.log('OK: studio-with-reservoir-desktop.png');

        // Crop the left rail (~320px) for a focused review screenshot.
        const reservoir = page.locator('[data-role="context-reservoir"]');
        if (await reservoir.count()) {
          await reservoir.screenshot({ path: `${OUT_DIR}/reservoir-rail-only.png` });
          console.log('OK: reservoir-rail-only.png');
        }
      }
    } else {
      console.log('no documents found — skipping populated shot');
    }
  }

  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
