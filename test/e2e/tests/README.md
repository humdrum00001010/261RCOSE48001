# ecrits Playwright e2e

Drives real Chromium against the **public sprite URL**
`https://ecrits-studio-v7zk.sprites.app/`.

Not `localhost:4002`. Not in-process. Not Wallaby. See
the private local assistant memory note `feedback-browser-persona-tests` for the
binding acceptance bar.

## Run

```bash
pnpm install
npx playwright install chromium
npx playwright install-deps chromium  # Linux only, first time

pnpm test              # headless, all browsers
pnpm test:headed       # eyeballs
pnpm test:trace        # always-on trace
pnpm report            # open last HTML report
```

## Config

| Env                 | Default                                          | Purpose                                                                |
| ------------------- | ------------------------------------------------ | ---------------------------------------------------------------------- |
| `E2E_BASE_URL`      | `https://ecrits-studio-v7zk.sprites.app`       | Override to point at a different sprite (or a tunneled local).         |
| `SPRITE_TOKEN`      | unset                                            | If the sprite URL is configured with `--auth token`, set this to the token. |
| `CI`                | unset                                            | `1` in CI: enables retries, narrower workers.                          |

## Test-only Elixir routes

The Phoenix app exposes two routes when
`Application.compile_env(:ecrits, :test_auth, false)` is `true`
(currently `true` in `:dev` and `:test`, `false` in `:prod`):

* `POST /test/personas/:persona/sign_in` — mints a fresh confirmed user
  via `Ecrits.PersonaFactory`, sets the session cookie, returns
  `{ ok: true, persona, user_id, email }`.
* `POST /test/reset` — runs `Ecrits.E2E.reset!/0`, which tears down
  the `e2e` matter scope.

In production both routes 404 (compile-time elision via `compile_env`).

## Scenarios

| File                | Status     | Covers                                                                 |
| ------------------- | ---------- | ---------------------------------------------------------------------- |
| `smoke.spec.ts`     | live       | Each persona signs in and reaches the home page over the public URL.   |

Wave 3C1 (Studio LV) inherits this harness and adds:

* briefing → grill → edit
* socket reconnect
* Cmd+K palette
* agent_supervised watcher
