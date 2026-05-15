import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for Contract Studio e2e tests.
 *
 * `E2E_BASE_URL` defaults to the public sprite URL — tests MUST hit a real
 * server over the real internet (HTTP/2 + TLS + sprite proxy + real DNS),
 * not localhost. See
 * ~/.claude/projects/-home-ereignis/memory/feedback-browser-persona-tests.md.
 *
 * `SPRITE_TOKEN` is forwarded as `X-Sprite-Token` so we can run against a
 * sprite URL configured with `--auth token`. With `--auth none` the header
 * is harmless.
 */

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : 4,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }]
  ],
  use: {
    baseURL: BASE_URL,
    trace: 'on-first-retry',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
    extraHTTPHeaders: process.env.SPRITE_TOKEN
      ? { 'X-Sprite-Token': process.env.SPRITE_TOKEN }
      : {},
    ignoreHTTPSErrors: false
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] }
    }
  ]
});
