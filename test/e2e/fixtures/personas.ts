import { Page, expect, APIRequestContext } from '@playwright/test';

/**
 * The five canonical personas. Backed by `Contract.PersonaFactory` on the
 * Elixir side. The Playwright runner POSTs `/test/personas/:persona/sign_in`
 * (route gated by `Application.compile_env(:contract, :test_auth)`); the
 * server mints a fresh confirmed user, sets a real session cookie, and
 * returns the user id.
 */
export type Persona =
  | 'lawyer'
  | 'paralegal'
  | 'agent_supervised'
  | 'viewer'
  | 'admin';

export const PERSONAS: Persona[] = [
  'lawyer',
  'paralegal',
  'agent_supervised',
  'viewer',
  'admin'
];

export interface SignInResponse {
  ok: boolean;
  persona: Persona;
  user_id: string;
  email: string;
}

/**
 * Signs the given `page` (i.e. its BrowserContext) in as `persona`. The
 * session cookie set by the server is automatically retained in the
 * BrowserContext for the rest of the test.
 *
 * Retries on 5xx: `Contract.PersonaFactory.build/1` has a small email-collision
 * window (random suffix space ~10k) that can flake under parallel sign-ins.
 * Retrying with a fresh request usually resolves on the next attempt — the
 * suffix re-rolls every call.
 */
export async function signInAs(page: Page, persona: Persona): Promise<SignInResponse> {
  const maxAttempts = 5;
  let lastStatus = 0;
  let lastText = '';

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const resp = await page.request.post(`/test/personas/${persona}/sign_in`);
    lastStatus = resp.status();
    if (lastStatus === 200) {
      const body = (await resp.json()) as SignInResponse;
      expect(body.ok).toBe(true);
      expect(body.persona).toBe(persona);
      return body;
    }
    lastText = await resp.text().catch(() => '');
    // Back off briefly so the random email suffix shifts to a different
    // millisecond bucket on the next try.
    await new Promise((r) => setTimeout(r, 50 * attempt));
  }

  throw new Error(
    `signInAs(${persona}) failed after ${maxAttempts} attempts. Last status=${lastStatus}, body=${lastText.slice(0, 200)}`
  );
}

/**
 * Wipes the `e2e` matter scope. Idempotent. Call from `test.beforeEach`
 * (or `test.afterAll`) for any scenario that touches Studio rows.
 */
export async function resetE2EState(request: APIRequestContext): Promise<void> {
  const resp = await request.post('/test/reset', { failOnStatusCode: true });
  expect(resp.status()).toBe(200);
}
