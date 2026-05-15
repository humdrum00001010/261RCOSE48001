/**
 * Landing UX audit — Wave 3C0-F.
 *
 * Drives a real Chromium against the public sprite URL and exercises every
 * clickable element on the landing page:
 *
 *   1. Enumerate <a>/<button> elements; capture text, href/navigate, parent
 *      form, computed CSS (pointer-events, display, cursor), bounding box.
 *   2. For each navigable element (href OR data-phx-link), open a fresh
 *      page, click it, wait for navigation, capture final URL + status.
 *   3. Special-case diagnostics for the top-nav "Register" button and for
 *      the hero inline links ("도입 검토 →", "로그인").
 *
 *   sprite x -s contract-studio -- bash -lc \
 *     'cd ~/work/contract/test/e2e && pnpm tsx scripts/landing-ux-audit.ts \
 *     | tee /tmp/landing-ux-audit.log'
 */
import {
  chromium,
  type Browser,
  type BrowserContext,
  type Page,
  type Locator
} from '@playwright/test';

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

interface ClickableSnapshot {
  index: number;
  tag: string;
  text: string;
  href: string | null;
  phxLink: string | null;
  type: string | null;
  parentFormTag: string | null;
  pointerEvents: string;
  display: string;
  cursor: string;
  visible: boolean;
}

async function snapshotClickable(
  locator: Locator,
  index: number
): Promise<ClickableSnapshot | null> {
  const box = await locator.boundingBox().catch(() => null);
  const handle = await locator.elementHandle();
  if (!handle) return null;
  const data = await handle.evaluate((el: Element) => {
    const cs = getComputedStyle(el);
    let parent: Element | null = el.parentElement;
    let parentFormTag: string | null = null;
    while (parent) {
      if (parent.tagName === 'FORM') {
        parentFormTag = `<form action="${parent.getAttribute('action') ?? ''}" method="${parent.getAttribute('method') ?? ''}">`;
        break;
      }
      parent = parent.parentElement;
    }
    return {
      tag: el.tagName.toLowerCase(),
      text: (el.textContent ?? '').trim().slice(0, 80),
      href: el.getAttribute('href'),
      phxLink: el.getAttribute('data-phx-link'),
      type: el.getAttribute('type'),
      parentFormTag,
      pointerEvents: cs.pointerEvents,
      display: cs.display,
      cursor: cs.cursor
    };
  });
  await handle.dispose();
  return {
    index,
    ...data,
    visible: box !== null
  };
}

async function clickAndTrace(
  context: BrowserContext,
  snap: ClickableSnapshot
): Promise<{ ok: boolean; finalUrl: string; status: number | null; note: string }> {
  const page = await context.newPage();
  let status: number | null = null;
  page.on('response', (resp) => {
    if (resp.url() === page.url() || resp.request().isNavigationRequest()) {
      const s = resp.status();
      // Last navigation status wins.
      if (resp.request().isNavigationRequest()) status = s;
    }
  });
  await page.goto(`${BASE_URL}/`, {
    waitUntil: 'networkidle',
    timeout: 30_000
  });

  // Re-locate by index — the page state must match the original snapshot.
  const all = page.locator('a, button');
  const target = all.nth(snap.index);
  const startUrl = page.url();
  try {
    await Promise.race([
      Promise.all([
        page.waitForURL((u) => u.toString() !== startUrl, { timeout: 5_000 }),
        target.click({ timeout: 3_000 })
      ]),
      // Fallback timer — some buttons just don't navigate.
      page.waitForTimeout(3_500).then(() => {
        throw new Error('no navigation within 3.5s');
      })
    ]);
    await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {});
    const finalUrl = page.url();
    const ok = finalUrl !== startUrl;
    await page.close();
    return {
      ok,
      finalUrl,
      status,
      note: ok ? 'navigated' : 'click registered but no URL change'
    };
  } catch (err) {
    const finalUrl = page.url();
    const note = (err as Error).message;
    await page.close();
    return {
      ok: finalUrl !== startUrl,
      finalUrl,
      status,
      note
    };
  }
}

async function run(): Promise<void> {
  const browser: Browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    baseURL: BASE_URL,
    viewport: { width: 1440, height: 900 }
  });

  // ---- Phase 1: enumerate clickables ----
  const page: Page = await context.newPage();
  await page.goto(`${BASE_URL}/`, {
    waitUntil: 'networkidle',
    timeout: 30_000
  });

  const all = page.locator('a, button');
  const total = await all.count();
  console.log(`\n[enumerate] ${total} clickable elements found on landing.\n`);

  const snaps: ClickableSnapshot[] = [];
  for (let i = 0; i < total; i++) {
    const snap = await snapshotClickable(all.nth(i), i);
    if (!snap) continue;
    if (!snap.visible) {
      console.log(
        `  [${i}] (offscreen/no-box) ${snap.tag} text="${snap.text}"`
      );
      continue;
    }
    snaps.push(snap);
    console.log(
      `  [${i}] <${snap.tag}> text="${snap.text}"` +
        ` href=${JSON.stringify(snap.href)}` +
        ` phx-link=${JSON.stringify(snap.phxLink)}` +
        ` type=${JSON.stringify(snap.type)}` +
        ` parentForm=${snap.parentFormTag ?? 'none'}` +
        ` pointer-events=${snap.pointerEvents}` +
        ` display=${snap.display}` +
        ` cursor=${snap.cursor}`
    );
  }
  console.log(`\n[enumerate] ${snaps.length} visible clickables.\n`);

  // ---- Phase 2: click each navigable target in a fresh page ----
  console.log(`[click] driving each navigable target ...\n`);
  let okCount = 0;
  let brokenCount = 0;
  for (const snap of snaps) {
    const isNavigable =
      (snap.href && snap.href !== '#' && !snap.href.startsWith('mailto:')) ||
      snap.phxLink;
    // Skip in-page anchors (#docs, #changelog) and mailto.
    const isHashAnchor = snap.href && snap.href.startsWith('#');
    const isMailto = snap.href && snap.href.startsWith('mailto:');
    const isHashRoute =
      snap.href && (snap.href.startsWith('/#') || snap.href === '/');
    const isLogoSelf = snap.href === '/';

    const label = `[${snap.index}] "${snap.text}" → ${snap.href ?? snap.phxLink ?? '(none)'}`;

    if (!isNavigable) {
      console.log(`  ${label} → SKIP (no nav target; tag=${snap.tag} type=${snap.type})`);
      continue;
    }
    if (isHashAnchor || isMailto) {
      console.log(`  ${label} → SKIP (anchor/mailto)`);
      continue;
    }
    if (isHashRoute || isLogoSelf) {
      // The wordmark navigates to "/" which is the same page; not interesting.
      console.log(`  ${label} → SKIP (self-link)`);
      continue;
    }

    const result = await clickAndTrace(context, snap);
    const tag = result.ok ? 'OK' : 'BROKEN';
    if (result.ok) okCount++;
    else brokenCount++;
    console.log(
      `  ${label} → ${tag} (final=${result.finalUrl}, status=${result.status ?? '?'}, note=${result.note})`
    );
  }

  // ---- Phase 3: the top-nav "Register" deep-dive ----
  console.log(`\n[register-deepdive] top-nav Register button:\n`);
  const registerSnap = snaps.find(
    (s) => s.text.toLowerCase().includes('register') && !s.text.toLowerCase().includes('도입')
  );
  if (!registerSnap) {
    console.log(`  NOT FOUND.`);
  } else {
    console.log(JSON.stringify(registerSnap, null, 2));
    const result = await clickAndTrace(context, registerSnap);
    console.log(`  click outcome: ${JSON.stringify(result, null, 2)}`);
    if (!result.ok) {
      console.log(`  >>> BUTTON DEAD <<<`);
    }
  }

  // ---- Phase 4: hero inline CTA deep-dives ----
  console.log(`\n[hero-deepdive] hero "도입 검토 →" + "로그인":\n`);
  for (const needle of ['도입 검토', '로그인']) {
    const heroSnap = snaps.find((s) => s.text.includes(needle));
    if (!heroSnap) {
      console.log(`  "${needle}" NOT FOUND.`);
      continue;
    }
    console.log(`  "${needle}":`, JSON.stringify(heroSnap, null, 2));
    const result = await clickAndTrace(context, heroSnap);
    console.log(`  click outcome: ${JSON.stringify(result, null, 2)}`);
  }

  console.log(`\n[summary] ok=${okCount} broken=${brokenCount} total-tested=${okCount + brokenCount}\n`);

  await page.close();
  await context.close();
  await browser.close();
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
