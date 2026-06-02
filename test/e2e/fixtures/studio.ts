import { APIRequestContext, Page, expect } from '@playwright/test';

/**
 * Shared Studio helpers for the Wave 3C1 scenario specs. These wrap the
 * test-only HTTPS endpoints exposed by `EcritsWeb.TestDbController`
 * (`/test/db/*`) and the test-only auth + reset routes from
 * `EcritsWeb.TestAuthController`.
 *
 * Every helper returns a normal Promise — no Playwright fixtures, no
 * test.use() magic — so individual specs can decide whether to reset
 * state, fetch DB rows, or just navigate.
 */

export interface ChangeRow {
  id: string;
  action_kind: string;
  applied_revision: number;
  base_revision: number | null;
  status: 'active' | 'revoked' | 'partially_revoked' | 'superseded';
  actor_type: string;
  idempotency_key: string | null;
  inserted_at: string;
}

export interface DocumentRow {
  id: string;
  name: string | null;
  type_key: string | null;
  inserted_at: string;
}

export interface ObanJobRow {
  id: number;
  queue: string;
  worker: string;
  args: Record<string, unknown>;
  state: string;
  attempt: number;
  max_attempts: number;
  inserted_at: string;
  completed_at: string | null;
  discarded_at: string | null;
  cancelled_at: string | null;
  errors: unknown[];
}

/**
 * Fetch all `changes` for `documentId` ordered by `applied_revision asc`.
 * Returns `[]` if the document has no changes or the table is missing.
 */
export async function getChanges(
  request: APIRequestContext,
  documentId: string
): Promise<ChangeRow[]> {
  const resp = await request.get(`/test/db/changes/${documentId}`);
  expect(resp.status()).toBe(200);
  const body = (await resp.json()) as { ok: boolean; changes: ChangeRow[] };
  return body.changes;
}

/**
 * Fetch the full document list (most recent first). Useful when the
 * scenario needs to find a doc by name without knowing the id up front.
 */
export async function getDocuments(
  request: APIRequestContext
): Promise<DocumentRow[]> {
  const resp = await request.get('/test/db/documents');
  expect(resp.status()).toBe(200);
  const body = (await resp.json()) as { ok: boolean; documents: DocumentRow[] };
  return body.documents;
}

/**
 * Fetch the latest Oban jobs for `queue`. The result is ordered newest
 * first; pass a queue name to inspect specific workers.
 */
export async function getObanJobs(
  request: APIRequestContext,
  queue = 'default'
): Promise<ObanJobRow[]> {
  const resp = await request.get(`/test/db/oban_jobs?queue=${encodeURIComponent(queue)}`);
  expect(resp.status()).toBe(200);
  const body = (await resp.json()) as { ok: boolean; jobs: ObanJobRow[] };
  return body.jobs;
}

/**
 * Polls until `predicate` returns true or the deadline elapses. Returns
 * the last value seen on resolve, throws on timeout. The poll interval
 * is `intervalMs` (default 250 ms); the timeout defaults to 10 s.
 */
export async function pollUntil<T>(
  fetcher: () => Promise<T>,
  predicate: (v: T) => boolean,
  opts: { timeoutMs?: number; intervalMs?: number; label?: string } = {}
): Promise<T> {
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const intervalMs = opts.intervalMs ?? 250;
  const label = opts.label ?? 'pollUntil';
  const start = Date.now();
  let last: T;

  while (true) {
    last = await fetcher();
    if (predicate(last)) return last;
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `${label}: predicate not satisfied within ${timeoutMs}ms. Last value: ${JSON.stringify(last)}`
      );
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

/**
 * Detects whether a Studio document is reachable via the LV. If the
 * `documents` table is empty (because Wave 3C1's migration hasn't landed
 * in the env Playwright is hitting), every studio-scenario test
 * test.skip()s with a documented reason — so the harness still completes
 * cleanly instead of erroring on `null` document ids.
 */
export async function findOrSkipDocument(
  request: APIRequestContext
): Promise<DocumentRow | null> {
  const docs = await getDocuments(request);
  return docs[0] ?? null;
}

/**
 * Navigates `page` to the Studio LV for `document`. When called without a
 * the Studio document-first route, which the LV resolves via
 * `Studio.load/2`.
 */
export async function openStudio(
  page: Page,
  document: DocumentRow
): Promise<void> {
  const route = `/documents/${document.id}`;
  await page.goto(route);
}
