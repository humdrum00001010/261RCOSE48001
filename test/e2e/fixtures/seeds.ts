import { APIRequestContext, Page, expect } from '@playwright/test';

/**
 * Resolves a request context. Prefer the page-scoped `request` so the
 * seed call rides the same cookie jar as the browser session set by
 * `signInAs(page, ...)`. Falls back to a raw `APIRequestContext` for
 * callers that explicitly want anonymous seeding (the controller will
 * mint a throwaway lawyer persona on the fly).
 */
function resolveRequest(arg: APIRequestContext | Page): APIRequestContext {
  // Playwright's Page exposes `.request`; the bare APIRequestContext
  // does not. Duck-type on the presence of `.context` to distinguish.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const maybePage = arg as any;
  if (maybePage && typeof maybePage.request === 'object' && maybePage.context) {
    return maybePage.request as APIRequestContext;
  }
  return arg as APIRequestContext;
}

/**
 * Programmatic seed helpers for Studio E2E scenario specs.
 *
 * Studio specs seed owner-scoped Documents directly through the test-only
 * `EcritsWeb.TestDbController` route (`POST /test/db/documents`), gated by
 * `Application.compile_env(:ecrits, :test_auth)` so it 404s in production
 * builds.
 *
 * Each helper expects the Playwright `APIRequestContext` to share a cookie jar
 * with the page under test (i.e. call `signInAs(page, ...)` before seeding) so
 * the controller can read the `user_token` from the session and attribute
 * document ownership. If no session is present the seeder falls back to a
 * throwaway lawyer persona and still creates an owner-scoped row.
 */

export interface SeededDocument {
  id: string;
  owner_id: string;
  type_key: string;
  title: string;
}

export interface SeedDocumentBundle {
  document: SeededDocument;
}

/**
 * Seeds an owner-scoped document. The test controller tags the row with E2E
 * metadata so `/test/reset` can remove it without relying on legacy matters.
 */
export async function seedDocument(
  request: APIRequestContext | Page,
  opts: { type_key?: string; title?: string } = {}
): Promise<SeededDocument> {
  const ctx = resolveRequest(request);
  const resp = await ctx.post('/test/db/documents', {
    data: {
      type_key: opts.type_key ?? 'nda_v1',
      title: opts.title ?? 'E2E doc'
    }
  });
  expect(resp.status(), `seedDocument: expected 200, got ${resp.status()}`).toBe(200);
  const body = (await resp.json()) as {
    ok: boolean;
    id: string;
    owner_id: string;
    type_key: string;
    title: string;
  };
  expect(body.ok).toBe(true);
  return {
    id: body.id,
    owner_id: body.owner_id,
    type_key: body.type_key,
    title: body.title
  };
}

/**
 * Seeds the document bundle shape used by Studio scenario specs.
 */
export async function seedDocumentBundle(
  request: APIRequestContext | Page,
  opts: {
    title?: string;
    type_key?: string;
  } = {}
): Promise<SeedDocumentBundle> {
  const document = await seedDocument(request, {
    type_key: opts.type_key,
    title: opts.title
  });
  return { document };
}
