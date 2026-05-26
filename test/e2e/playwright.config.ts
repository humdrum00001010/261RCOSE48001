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
 *
 * Viewports (Wave 3C1 / chat-first responsive scope —
 * see feedback-responsive-scope.md):
 *
 *   - chromium-desktop: 1440x900 (3-pane Studio layout)
 *   - chromium-mobile:  375x667  (chat-first Studio layout)
 *
 * Env switches:
 *
 *   - WAVE_4_READY=1    — include scenarios that depend on Wave 4 logic
 *                         reserved for feature-gated smoke paths.
 *   - EXPENSIVE_E2E=0   — skip scenarios that hit real OpenAI / Upstage
 *                         (briefing-grill-edit, two-session-grill-fanout).
 *
 * Tag-based gating happens inside the specs via `test.skip(...)`; the
 * config only configures the runner.
 */

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : 4,
  timeout: 60_000,
  expect: {
    timeout: 10_000
  },
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
      name: 'chromium-desktop',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 900 }
      }
    },
    {
      name: 'chromium-mobile',
      use: {
        // Force the Chromium engine — `devices['iPhone SE']` ships with
        // `defaultBrowserType: 'webkit'` which we don't have installed on
        // the sprite. We keep the iPhone-ish viewport + UA + touch but
        // run Chromium underneath.
        ...devices['Pixel 5'],
        viewport: { width: 375, height: 667 },
        isMobile: true,
        hasTouch: true,
        defaultBrowserType: 'chromium'
      }
    }
  ]
});
