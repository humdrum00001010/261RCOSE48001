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
 */
export async function signInAs(page: Page, persona: Persona): Promise<SignInResponse> {
  const resp = await page.request.post(`/test/personas/${persona}/sign_in`, {
    failOnStatusCode: true
  });
  expect(resp.status()).toBe(200);
  const body = (await resp.json()) as SignInResponse;
  expect(body.ok).toBe(true);
  expect(body.persona).toBe(persona);
  return body;
}

/**
 * Wipes the `e2e` matter scope. Idempotent. Call from `test.beforeEach`
 * (or `test.afterAll`) for any scenario that touches Studio rows.
 */
export async function resetE2EState(request: APIRequestContext): Promise<void> {
  const resp = await request.post('/test/reset', { failOnStatusCode: true });
  expect(resp.status()).toBe(200);
}
