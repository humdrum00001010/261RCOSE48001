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
 * Programmatic seed helpers for the Wave 3C1 scenario specs.
 *
 * These hit the test-only POST endpoints exposed by
 * `ContractWeb.TestDbController` (`POST /test/db/matters`,
 * `POST /test/db/documents`), which are gated by
 * `Application.compile_env(:contract, :test_auth)` — so they 404 in
 * production builds.
 *
 * Each helper expects the Playwright `APIRequestContext` to share a
 * cookie jar with the page under test (i.e. you must call
 * `signInAs(page, ...)` before seeding so the controller can read the
 * `user_token` from the session and attribute ownership). If no session
 * is present the seeder falls back to a throwaway lawyer persona; the
 * resulting matter then has `tenant_id: nil`, which is read-visible to
 * any scope.
 */

export interface SeededMatter {
  id: string;
  name: string;
}

export interface SeededDocument {
  id: string;
  matter_id: string;
  type_key: string;
  title: string;
}

export interface SeedBundle {
  matter: SeededMatter;
  document: SeededDocument;
}

/**
 * Seeds a single matter. Returns the new matter's id + name.
 */
export async function seedMatter(
  request: APIRequestContext | Page,
  opts: { name?: string } = {}
): Promise<SeededMatter> {
  const ctx = resolveRequest(request);
  const resp = await ctx.post('/test/db/matters', {
    data: { name: opts.name ?? 'E2E matter' }
  });
  expect(resp.status(), `seedMatter: expected 200, got ${resp.status()}`).toBe(200);
  const body = (await resp.json()) as { ok: boolean; id: string; name: string };
  expect(body.ok).toBe(true);
  return { id: body.id, name: body.name };
}

/**
 * Seeds a document inside an existing matter.
 */
export async function seedDocument(
  request: APIRequestContext | Page,
  opts: { matter_id: string; type_key?: string; title?: string }
): Promise<SeededDocument> {
  const ctx = resolveRequest(request);
  const resp = await ctx.post('/test/db/documents', {
    data: {
      matter_id: opts.matter_id,
      type_key: opts.type_key ?? 'nda_v1',
      title: opts.title ?? 'E2E doc'
    }
  });
  expect(resp.status(), `seedDocument: expected 200, got ${resp.status()}`).toBe(200);
  const body = (await resp.json()) as {
    ok: boolean;
    id: string;
    matter_id: string;
    type_key: string;
    title: string;
  };
  expect(body.ok).toBe(true);
  return {
    id: body.id,
    matter_id: body.matter_id,
    type_key: body.type_key,
    title: body.title
  };
}

/**
 * Convenience: seeds a matter and a document inside it in one call.
 * The default `type_key` is `nda_v1`. Returns both rows so the scenario
 * can navigate to `/matters/${matter.id}/documents/${document.id}`.
 */
export async function seedMatterAndDocument(
  request: APIRequestContext | Page,
  opts: {
    matter_name?: string;
    title?: string;
    type_key?: string;
  } = {}
): Promise<SeedBundle> {
  const matter = await seedMatter(request, { name: opts.matter_name });
  const document = await seedDocument(request, {
    matter_id: matter.id,
    type_key: opts.type_key,
    title: opts.title
  });
  return { matter, document };
}
