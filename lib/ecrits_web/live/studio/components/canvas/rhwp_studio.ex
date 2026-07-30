defmodule EcritsWeb.Live.Studio.Components.Canvas.RhwpStudio do
  @moduledoc """
  HWP/HWPX canvas hosted as an **rhwp-studio iframe**, driven over studio's embed
  RPC (protocol v1).

  Layer 4 of `docs/plans/2026-07-26-doclang-engine-migration.md`. The deleted
  `:ehwp` dep supplied both the server NIF and the `rhwp_bg.wasm` the legacy
  `Canvas.HwpPages` hook loaded from `/assets/rhwp/`; with the dep gone that hook
  has no engine. rhwp-studio brings its own engine, its own renderer and its own
  editing UI, so the host stops owning canvas/hit-testing/input entirely and only
  keeps the transport.

  ## Transport

  `rhwp_core/rhwp-studio/src/embed/{protocol,runtime,rpc-router}.ts`. The host
  posts `{type: "rhwp-connect", version: 1, sessionId, capabilities}` to the
  iframe with one `MessagePort` transferred; studio binds the first valid connect
  and answers `rhwp-connected`. Everything after that is
  `rhwp-request{id, method, params}` / `rhwp-response{id, result | error}` on that
  port. Binary results ride back as transferred `Uint8Array`s
  (`transferable-array-buffer`).

  The connect is retried on a short interval rather than posted once on iframe
  `load`: studio installs its listener when `main.ts` finishes evaluating, and a
  connect posted before that is silently dropped (there is no listener yet).
  Studio drops every connect after the first binding, so the retries are free.

  ## Two canvases, one component

  `mirror?` splits this component in half. The **editor** (`mirror?: false`) is
  the iframe above: one studio instance per open document, driving every verb
  below. A **mirror** is a chat-rail preview card — inert by construction
  (`pointer-events-none`, no toolbar, no command ever routed to it) — and it
  renders **no iframe at all**. It paints a single page SVG produced by ONE
  invisible studio instance shared by every mirror on the page.

  That asymmetry is the whole cost argument. A card is created per committed
  edit and the bundle carries a 24 MB `rhwp_bg.wasm` plus a 7 MB canvaskit, so N
  cards with their own iframes would mean N engines. Against the shared renderer
  a card costs one `loadFile` (only when its snapshot differs from the one
  already loaded) plus one `getPageSvg` — measured on a real 35-page Korean
  document: 604 ms and 76 ms, 1.1 s from card mount to painted page including
  the engine's cold boot. Repeat mounts of the same snapshot cost nothing: the
  rendered pages are cached as blobs and outlive the engine, which is torn down
  after a minute with no live card.

  The renderer iframe is invisible but deliberately **inside the viewport**
  (2 px, `opacity: 0`). A frame the browser does not render has its timers
  throttled to ~1 Hz, and studio awaits a paint between each of its load-progress
  steps: the same `loadFile` measured **9.3 s parked offscreen against 0.6 s in
  the viewport**. Do not "tidy" this into `display: none` or a negative offset.

  The page shown is the one carrying the edit, and the edit is **marked on it**.
  A preview highlight names a ref (or the text that was written); `docFind`
  resolves the text when there is no usable ref, and `docRects`
  (**`doc-rects-v1`**, added upstream for this) answers both the page and the
  per-line rectangles the range occupies. Those rectangles are in the same
  page-px space as `getPageSvg`'s `viewBox`, so the amber marks are spliced
  straight into the SVG string — one image, no sibling overlay, no resize
  listener, correct at every card size.

  Degradation is per-capability, not all-or-nothing: a bundle with `doc-ops-v1`
  but no `doc-rects-v1` still opens on the right page (via `docGet` ->
  `getPageOfPosition`) and just draws no marks. With no `doc-ops-v1` at all it is
  page 1 — never a blank card.

  ## Verb coverage

  `Ecrits.Doc.BrowserBridge` calls the browser with
  `read | find | edit | set | get | save | vfs_write | vfs_commit |
  vfs_finalize | vfs_rollback`. `save` rides the load/export methods embed v1
  always had. Everything else rides **`doc-ops-v1`**, the document-operation
  family upstream added to `rpc-router.ts` (`src/embed/doc-ops.ts`):

      docRead    docFind    docEdit    docSet    docGet
      docVfsWrite  docVfsCommit  docVfsFinalize  docVfsRollback

  Detection is a **capability string, not a version bump**: `EMBED_PROTOCOL_VERSION`
  stays `1` (studio's connect gate tests `version === 1` exactly, so bumping it
  would reject every existing host) and `doc-ops-v1` is advertised in the
  `rhwp-connected` reply's `capabilities`. This host therefore reads the
  capability off the handshake and, when it is absent — an older installed
  bundle — keeps failing the affected verb with the same precise
  `embed_rpc_gap:<verb>: …` message rather than assuming the methods exist.

  ## What this host translates

  doc-ops-v1 is a *primitive* surface: positional `insert_text` /
  `replace_text` / `delete_range` over `{section, paragraph, offset, cell}`, plus
  `applyCharFormat`/`setCellProperties` behind `docSet`. The BrowserBridge verbs
  are richer, so the mapping below is real work, not a rename:

    * ref grammar — the host speaks JSON refs *and* `Doc.Rhwp.Ref`'s
      `hwp:s0/p7`, `…/c<off>+<len>`, `…/tbl<c>/cell<i>/cp<p>/c<off>+<len>`
      strings. Both are parsed here into the `{section, paragraph, offset, cell}`
      object doc-ops takes (which also accepts `searchAllText` naming, so a
      `docFind` hit feeds straight back in).
    * `replace_text` is `{query, replacement}` on this side and positional
      `{ref, length, text}` on the other, so the query is **resolved to an offset
      first** — inside the ref'd paragraph/cell via `docRead`, else globally via
      `docFind` (keeping the legacy "matches N places, pass a ref" guard and
      `all: true`).
    * `set_cell` has no doc-op; it is lowered onto one `replace_text` per cell
      paragraph, the last one absorbing any extra lines (doc-ops' cell
      `insert_text` splits on newlines).
    * `insert_text` with `ref: "end"` resolves the tail through `docGet`.
    * a batch resolves EVERY op before sending one `docEdit`, so no read sees a
      half-mutated document; doc-ops then applies in reverse document order and
      reports in caller order.
    * `vfs_write` carries the document's own `format`, because the bytes it
      returns are written straight over the source file: the container has to be
      the one already behind that name. doc-ops defaults to the format the
      document was opened as, and echoes what it actually exported — this host
      checks that echo before uploading a byte (a bundle predating the selector
      omits it and only ever produced HWP, so a missing echo is read as `hwp`).

  ## The element picker rides `host-events-v1`

  Picking hands the AGENT a document reference by clicking. The office canvas
  hit-tests the click in its own DOM; studio renders inside an iframe that never
  hears the host's DOM events, so the pick has to travel the other way — and
  embed v1 had no server→host direction at all. Upstream now adds one:

      rhwp-event{event: "selection", payload}   # no id, no reply

  Same rule as `doc-ops-v1`: a **capability**, `host-events-v1`, not a version
  bump. It is **off** until the host subscribes, so a document nobody is picking
  from costs nothing on the wire; arming the toggle sends
  `setEventSubscription {events: ["selection"]}` and disarming sends `[]`.

  The payload's `ref` is the `{section, paragraph, offset, length, cell}` shape
  `docFind` already returns, so a pick lowers to `Doc.Rhwp.Ref`'s
  `hwp:s0/p7/c0+12` (or the `tbl/cell/cp` form) and drops straight back into
  `doc.edit` through the same `parseHostRef` — no second grammar.

  Two host policies live here rather than upstream, because they are UI
  decisions: only `reason: "pointer"` picks become chips (a `caret` push is
  keyboard motion, or the agent's own edit, not a user pointing at something),
  and a click with no drag is widened from a zero-width caret to the whole
  paragraph/cell — the unit the user actually pointed at.

  ## Verbs that still have no route — named, never faked

    * `doc.find` discovery mode (`all` / `regex` / `type`) enumerates *every*
      element including empty table cells; that is `WasmBridge.enumerateElements`.
      It IS routed now, but under its own `doc-elements-v1` capability and only
      as the `elements` verb — `doc.find` has not been rewired onto it. Literal
      find works.
    * `doc.set` with `kind: para | picture | field` needs `applyParaFormat`,
      `setPictureProperties`, `setFieldValue`. doc-ops-v1 routes only
      `applyCharFormat` + `setCellProperties`, so `char` and `cell` work.
    * `doc.edit` verbs beyond insert/replace/delete/set_cell (`insert_table`,
      `insert_picture`, `delete_node`, the table-structure family, notes,
      equations, shapes).
    * `set_cell` into a cell whose paragraph count exceeds the new line count —
      collapsing them needs `mergeParagraphInCell`.
    * `doc.read`'s table neighbourhood (row/column headers) — same enumeration
      gap as discovery find. Body paragraph windows work.

  Each of those fails with a message naming the missing upstream method, so an
  agent sees why instead of a browser timeout, and no edit is silently dropped.
  """

  use EcritsWeb, :html

  alias Ecrits.DocumentCanvasState

  attr :id, :string, required: true
  attr :state, :any, required: true

  def render(%{state: %DocumentCanvasState{}} = assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".RhwpStudioEmbed"
      role="region"
      aria-label={if(@state.mirror?, do: "Document preview", else: "Document pages")}
      class={[
        "relative h-full min-h-0 overflow-hidden bg-white",
        @state.mirror? && "pointer-events-none"
      ]}
      data-component="canvas-rhwp-studio"
      data-renderer="rhwp-studio"
      data-role="rhwp-studio-editor"
      data-canvas-state={DocumentCanvasState.encode(@state)}
    >
      <iframe
        :if={not @state.mirror?}
        id={"#{@id}-frame"}
        data-role="rhwp-studio-frame"
        src="/rhwp-studio/index.html"
        title="rhwp-studio"
        phx-update="ignore"
        class="h-full w-full border-0 bg-white"
        allow="clipboard-read; clipboard-write"
      ></iframe>
      <div
        :if={@state.mirror?}
        id={"#{@id}-preview"}
        data-role="rhwp-studio-preview"
        phx-update="ignore"
        class="relative flex h-full w-full items-center justify-center overflow-hidden bg-white"
      >
        <img
          data-role="rhwp-studio-preview-page"
          alt="Document preview page"
          hidden
          class="h-full w-full object-contain object-top"
        />
        <p
          data-role="rhwp-studio-preview-status"
          class="px-3 text-center text-[11px] leading-4 text-base-content/45"
        >
          Rendering preview…
        </p>
      </div>
      <script
        :type={Phoenix.LiveView.ColocatedHook}
        name=".RhwpStudioEmbed"
        phx-no-curly-interpolation
      >
        import { octet } from "phoenix-colocated/ecrits";

        // ── rhwp-studio embed protocol v1 ──────────────────────────────────────
        // Mirrors rhwp_core/rhwp-studio/src/embed/protocol.ts. `version` and the
        // `transferable-array-buffer` capability are both hard-checked by
        // isConnectMessage(); dropping either makes studio answer
        // `rhwp-connect-error` instead of binding.
        const EMBED_VERSION = 1;
        const DOC_OPS_CAPABILITY = "doc-ops-v1";
        const HOST_EVENTS_CAPABILITY = "host-events-v1";
        const DOC_RECTS_CAPABILITY = "doc-rects-v1";
        const DOC_ELEMENTS_CAPABILITY = "doc-elements-v1";
        const EMBED_CAPABILITIES = [
          "transferable-array-buffer",
          "hml-export",
          "renderer-diagnostics-v1",
          "notify-saved-v1",
          DOC_OPS_CAPABILITY,
          HOST_EVENTS_CAPABILITY,
          DOC_RECTS_CAPABILITY,
          DOC_ELEMENTS_CAPABILITY
        ];
        const CONNECT_TIMEOUT_MS = 30000;
        const CONNECT_RETRY_MS = 400;
        const CALL_TIMEOUT_MS = 60000;

        // Every method rpc-router.ts routes. Anything absent here has no
        // transport regardless of what the engine can do internally.
        const EMBED_METHODS = [
          "ready", "loadFile", "pageCount", "getRendererDiagnostics", "getPageSvg",
          "exportHwp", "exportHwpx", "exportHml", "getHmlSaveState",
          "exportHwpVerify", "notifySaved"
        ];

        // The doc-ops-v1 family. Routed only when the connected bundle advertises
        // the capability, so an older installed dist degrades to the gap error
        // below instead of timing out on an unknown method.
        const DOC_OPS_METHODS = [
          "docRead", "docFind", "docEdit", "docSet", "docGet",
          "docVfsWrite", "docVfsCommit", "docVfsFinalize", "docVfsRollback"
        ];

        // doc-rects-v1 — one method, gated on its OWN capability. It lives on the
        // same upstream handler object as doc-ops-v1, but a bundle built before it
        // advertises `doc-ops-v1` and would answer `Unknown method: docRects`, so
        // the two capabilities cannot be conflated.
        const DOC_RECTS_METHODS = ["docRects"];

        // doc-elements-v1 — the element enumerator that lifts this arm off
        // body-paragraphs-only. Gated on its OWN capability for the same reason
        // doc-rects-v1 is: it ships on the doc-ops handler object, so a bundle
        // built before it advertises `doc-ops-v1` and would answer
        // `Unknown method: docElements`. When absent, `verbElements` falls back
        // to the paragraph census below and keeps reporting
        // `coverage: "body_paragraphs", complete: false` — the projection is
        // narrower, never silently wrong.
        const DOC_ELEMENTS_METHODS = ["docElements"];

        // The host-events-v1 family — one request that turns studio's own
        // server-push on. Everything it enables arrives as `rhwp-event`
        // envelopes, which carry no id and expect no reply.
        const HOST_EVENTS_METHODS = ["setEventSubscription"];

        // BrowserBridge verbs that need doc-ops-v1. The value names the method
        // the connected bundle is missing, so a stale dist reads as "rebuild
        // rhwp-studio" instead of looking like a browser timeout.
        const EMBED_RPC_GAPS = {
          read: "docRead is a doc-ops-v1 method and the connected bundle does not advertise it",
          find: "docFind is a doc-ops-v1 method and the connected bundle does not advertise it",
          edit: "docEdit is a doc-ops-v1 method and the connected bundle does not advertise it",
          set: "docSet is a doc-ops-v1 method and the connected bundle does not advertise it",
          get: "docGet is a doc-ops-v1 method and the connected bundle does not advertise it",
          elements: "docGet/docRead are doc-ops-v1 methods and the connected bundle does not advertise them",
          vfs_write: "docVfsWrite is a doc-ops-v1 method and the connected bundle does not advertise it",
          vfs_commit: "docVfsCommit is a doc-ops-v1 method and the connected bundle does not advertise it",
          vfs_finalize: "docVfsFinalize is a doc-ops-v1 method and the connected bundle does not advertise it",
          vfs_rollback: "docVfsRollback is a doc-ops-v1 method and the connected bundle does not advertise it"
        };

        // Hook state lives beside the hook, never on it: colocated hooks in this
        // app are transports, and `EcritsWeb.ColocatedHookArchitectureTest`
        // enforces that they own no `this.*` controller fields.
        const sessions = new WeakMap();
        // Mirror (chat-rail preview) hooks. They hold no session at all — see the
        // shared preview renderer below.
        const previewCards = new WeakMap();

        function describeError(error) {
          return String((error && error.message) || error);
        }

        // ── element picker bridge ──────────────────────────────────────────────
        // The picker hands the AGENT a document reference by clicking. The office
        // (LibreOffice WASM) canvas hit-tests the click itself; studio renders in
        // its own iframe document and never hears the host's DOM events, so the
        // pick has to come the other way — over `rhwp-event{selection}`, which is
        // exactly what `host-events-v1` adds upstream.
        //
        // The wire in/out is otherwise identical to the office arm, so the
        // composer chips, the `DocumentElementPicker` schema and the Escape
        // handling are shared, not duplicated.
        const PICKER_STATE_EVENT = "ecrits:document-element-picker.state";
        const PICKER_BRIDGE_SELECTOR = '[data-role="document-element-picker-bridge"]';
        const PICK_TOGGLED_EVENT = "ecrits:document-element-picker.pick-toggled";

        function documentElementPickerEnabled() {
          const bridge = document.querySelector(PICKER_BRIDGE_SELECTOR);
          return !!bridge && bridge.dataset.enabled === "true";
        }

        function appendPickedElementToComposer(pick) {
          document.dispatchEvent(new CustomEvent(PICK_TOGGLED_EVENT, { detail: pick || {} }));
        }

        // `Doc.Rhwp.Ref`'s string grammar, built from the SAME `{section,
        // paragraph, offset, length, cell}` shape doc-ops speaks — so the chip an
        // agent receives round-trips straight back through `doc.edit`'s
        // `parseHostRef` with no translation.
        function encodeHwpRef(ref) {
          if (!ref || !Number.isSafeInteger(ref.paragraph)) return "";
          const section = Number.isSafeInteger(ref.section) ? ref.section : 0;
          const offset = Number.isSafeInteger(ref.offset) ? ref.offset : 0;
          const length = Number.isSafeInteger(ref.length) ? ref.length : 0;
          const cell = ref.cell;
          if (cell) {
            const parent = Number.isSafeInteger(cell.parentPara) ? cell.parentPara : ref.paragraph;
            return `hwp:s${section}/p${parent}/tbl${cell.control}/cell${cell.cell}` +
              `/cp${cell.cellPara}/c${offset}+${length}`;
          }
          return `hwp:s${section}/p${ref.paragraph}/c${offset}+${length}`;
        }

        // A click with no drag selects nothing, so a caret-only pick would carry
        // `c<off>+0` — a zero-width span the agent cannot edit or quote. Widen it
        // to the whole paragraph/cell, which is the unit the user actually
        // pointed at (the office arm resolves to an element for the same reason).
        function pickRefFrom(selection) {
          const ref = selection && selection.ref;
          if (!ref) return null;
          if (Number.isSafeInteger(ref.length) && ref.length > 0) return ref;
          const paragraphLength = Number.isSafeInteger(selection.paragraphLength)
            ? selection.paragraphLength
            : 0;
          return Object.assign({}, ref, { offset: 0, length: paragraphLength });
        }

        // Whitespace is collapsed by character code, not by a regex: this JS lives
        // in an Elixir heredoc, which eats backslash escapes, so a literal
        // pattern would silently lose its class markers.
        function pickLabel(text) {
          let out = "";
          let pendingSpace = false;
          for (const ch of String(text || "")) {
            if (ch === " " || ch.charCodeAt(0) <= 32) {
              pendingSpace = out.length > 0;
              continue;
            }
            if (pendingSpace) {
              out += " ";
              pendingSpace = false;
            }
            out += ch;
          }
          return out.length > 160 ? `${out.slice(0, 159)}…` : out;
        }

        // ── ref grammar ────────────────────────────────────────────────────────
        // The host addresses text two ways: a JSON object (what doc.find returns
        // and what the DocLang write-back carries) and `Doc.Rhwp.Ref`'s string
        // grammar. doc-ops-v1 takes only the object, so both are parsed here into
        // one internal shape: {section, paragraph, offset, length, cell}.

        function pickInt(source, keys) {
          for (const key of keys) {
            const value = source[key];
            if (Number.isSafeInteger(value)) return value;
            if (typeof value === "string" && value.trim() !== "") {
              const parsed = Number(value);
              if (Number.isSafeInteger(parsed)) return parsed;
            }
          }
          return null;
        }

        function intAfter(text, prefix) {
          if (text.indexOf(prefix) !== 0) return null;
          const parsed = Number(text.slice(prefix.length));
          return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
        }

        // `hwp:s0/p7`, `hwp:s0/p7@3`, `hwp:s0/p7/c3+5`,
        // `hwp:s0/p7/tbl0/cell4/cp0/c0+2`. Parsed by segment prefix rather than a
        // regex so nothing depends on how the surrounding heredoc treats escapes.
        function parseHwpRefString(text) {
          if (text.indexOf("hwp:") !== 0) return null;
          const out = { section: 0, paragraph: null, offset: 0, length: null, cell: null };
          let control = null;
          let cellIndex = null;
          let cellPara = 0;
          for (const part of text.slice(4).split("/")) {
            if (!part) continue;
            const at = part.split("@");
            const plus = at[0].split("+");
            const head = plus[0];
            const span = plus.length > 1 ? Number(plus[1]) : null;
            let value = intAfter(head, "cell");
            if (value !== null) {
              cellIndex = value;
              continue;
            }
            value = intAfter(head, "tbl");
            if (value !== null) {
              control = value;
              continue;
            }
            value = intAfter(head, "cp");
            if (value !== null) {
              cellPara = value;
              continue;
            }
            value = intAfter(head, "s");
            if (value !== null) {
              out.section = value;
              continue;
            }
            value = intAfter(head, "p");
            if (value !== null) {
              out.paragraph = value;
              if (at.length > 1 && Number.isSafeInteger(Number(at[1]))) out.offset = Number(at[1]);
              continue;
            }
            value = intAfter(head, "c");
            if (value !== null) {
              out.offset = value;
              if (span !== null && Number.isSafeInteger(span)) out.length = span;
            }
          }
          if (out.paragraph === null) return null;
          if (control !== null && cellIndex !== null) {
            out.cell = { parentPara: out.paragraph, control, cell: cellIndex, cellPara };
          }
          return out;
        }

        function parseCellRef(value, fallbackParagraph) {
          if (!value || typeof value !== "object") return null;
          const parentPara = pickInt(value, ["parentPara", "parentParaIndex", "parent_para"]);
          const control = pickInt(value, ["control", "controlIndex", "ctrlIdx"]);
          const cell = pickInt(value, ["cell", "cellIndex", "cellIdx"]);
          const cellPara = pickInt(value, ["cellPara", "cellParaIndex", "cell_para"]);
          const parent = parentPara === null ? fallbackParagraph : parentPara;
          if (parent === null || control === null || cell === null) return null;
          return { parentPara: parent, control, cell, cellPara: cellPara === null ? 0 : cellPara };
        }

        // A legacy `cellPath` addresses nested tables. doc-ops-v1's ref carries
        // exactly one table level, so a deeper path is refused by name rather
        // than silently flattened onto the wrong cell.
        function parseCellPath(raw, fallbackParagraph) {
          let list = raw;
          if (typeof list === "string" && list.trim() !== "") {
            try {
              list = JSON.parse(list);
            } catch (_) {
              return null;
            }
          }
          if (!Array.isArray(list) || list.length === 0) return null;
          if (list.length > 1) {
            throw new Error(
              "unsupported_ref: a nested cellPath has no doc-ops-v1 route (its ref addresses one table level)"
            );
          }
          return parseCellRef(list[0], fallbackParagraph);
        }

        function parseHostRef(raw) {
          if (raw == null) return null;
          if (typeof raw === "string") {
            const text = raw.trim();
            if (text === "" || text === "end") return null;
            if (text.charAt(0) === "{" || text.charAt(0) === "[") {
              let decoded = null;
              try {
                decoded = JSON.parse(text);
              } catch (_) {
                return null;
              }
              return parseHostRef(decoded);
            }
            return parseHwpRefString(text);
          }
          if (typeof raw !== "object") return null;
          const paragraph = pickInt(raw, ["paragraph", "paragraphIndex", "para"]);
          const cell =
            parseCellPath(raw.cellPath || raw.cell_path, paragraph) ||
            parseCellRef(raw.cell || raw.cellContext, paragraph);
          const resolved = paragraph === null ? (cell ? cell.parentPara : null) : paragraph;
          if (resolved === null) return null;
          const section = pickInt(raw, ["section", "sectionIndex", "sec"]);
          const offset = pickInt(raw, ["offset", "charOffset"]);
          return {
            section: section === null ? 0 : section,
            paragraph: resolved,
            offset: offset === null ? 0 : offset,
            length: pickInt(raw, ["length", "len"]),
            cell
          };
        }

        // doc-ops-v1's parseEmbedDocRef vocabulary.
        function wireRef(ref, offset) {
          const out = {
            section: ref.section,
            paragraph: ref.paragraph,
            offset: Number.isSafeInteger(offset) ? offset : ref.offset
          };
          if (ref.cell) {
            out.cell = {
              parentPara: ref.cell.parentPara,
              control: ref.cell.control,
              cell: ref.cell.cell,
              cellPara: ref.cell.cellPara
            };
          }
          return out;
        }

        function wireCellParaRef(ref, cellPara, offset) {
          const out = wireRef(ref, offset);
          if (out.cell) out.cell.cellPara = cellPara;
          return out;
        }

        // The ref shape every other host surface already reads (doc.find's reply,
        // the DocLang write-back, `Doc.Rhwp.Ref`), so a ref this hook mints can be
        // handed straight back to it.
        function refJson(ref) {
          const out = { section: ref.section, paragraph: ref.paragraph, offset: ref.offset };
          if (ref.cell) {
            out.cell = {
              parentParaIndex: ref.cell.parentPara,
              controlIndex: ref.cell.control,
              cellIndex: ref.cell.cell,
              cellParaIndex: ref.cell.cellPara
            };
          }
          return JSON.stringify(out);
        }

        function refLabel(raw) {
          if (raw == null) return null;
          return typeof raw === "string" ? raw : JSON.stringify(raw);
        }

        function hitToRef(hit) {
          const cell = hit && hit.cell;
          return {
            section: hit.section || 0,
            paragraph: hit.paragraph || 0,
            offset: hit.offset || 0,
            length: hit.length,
            cell: cell
              ? {
                  parentPara: cell.parentPara,
                  control: cell.control,
                  cell: cell.cell,
                  cellPara: cell.cellPara
                }
              : null
          };
        }

        function splitLines(value) {
          return String(value == null ? "" : value)
            .split("\r\n")
            .join("\n")
            .split("\r")
            .join("\n")
            .split("\n");
        }

        function boundedInt(value, fallback) {
          return Number.isSafeInteger(value) && value >= 0 ? Math.min(value, 10) : fallback;
        }

        // ── char property vocabulary ───────────────────────────────────────────
        // doc-ops' docSet hands `props` to applyCharFormat verbatim, so the
        // agent-facing (and UNO-facing) names still have to be lowered to the
        // engine's. Ported from the legacy hook's CHAR_PROP_SPEC.
        const CHAR_PROP_SPEC = {
          CharWeight: ["bold", "weightThreshold"],
          FontWeight: ["bold", "fontWeight"],
          CharPosture: ["italic", "positive"],
          CharUnderline: ["underline", "positive"],
          CharColor: ["textColor", "verbatim"],
          CharHeight: ["fontSize", "fontSize"],
          Bold: ["bold", "bool"],
          Italic: ["italic", "bool"],
          Underline: ["underline", "bool"],
          Strikethrough: ["strikethrough", "bool"],
          TextColor: ["textColor", "verbatim"],
          FontSize: ["fontSize", "fontSize"],
          fontSize: ["fontSize", "fontSize"],
          FontFamily: ["fontFamily", "verbatim"],
          FontId: ["fontId", "int"]
        };

        function castCharProp(type, value) {
          switch (type) {
            case "bool":
              return !!value;
            case "weightThreshold":
              return Number(value) >= 150;
            case "fontWeight":
              return value === "bold" || Number(value) >= 600;
            case "positive":
              return Number(value) > 0;
            case "int":
              return Math.round(Number(value));
            // fontSize is 1/100 pt (10pt = 1000); a point-scale value (<=200) is
            // POINTS -> x100, else it is already 1/100pt.
            case "fontSize": {
              const n = Number(value);
              return n <= 0 ? 1000 : n <= 200 ? Math.round(n * 100) : Math.round(n);
            }
            default:
              return value;
          }
        }

        function translateCharProps(props) {
          const out = {};
          for (const key of Object.keys(props)) {
            const spec = CHAR_PROP_SPEC[key];
            if (spec) out[spec[0]] = castCharProp(spec[1], props[key]);
            else out[key] = props[key];
          }
          return out;
        }

        function readCanvasState(el) {
          const raw = el.getAttribute("data-canvas-state");
          if (!raw) return {};
          try {
            return JSON.parse(raw) || {};
          } catch (_) {
            return {};
          }
        }

        // ── embed transport ────────────────────────────────────────────────────
        // One studio window, one MessagePort, one request/response map. Split out
        // of the canvas session because the mirror preview renderer (below) drives
        // a studio instance that belongs to no hook at all.
        function createTransport(resolveWindow) {
          const sessionId = `ecrits-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
          const pending = new Map();
          // host-events-v1 listeners. Notifications carry no id, so they never
          // touch `pending` — a stray event cannot settle or leak a request.
          const listeners = new Set();
          const state = {
            port: null,
            connecting: null,
            nextId: 1,
            loadedUrl: null,
            destroyed: false,
            // Advertised by the `rhwp-connected` reply. `doc-ops-v1` lives here
            // rather than in EMBED_VERSION because studio's connect gate tests
            // `version === 1` exactly.
            capabilities: []
          };

          function settle(data) {
            const entry = pending.get(data.id);
            if (!entry) return;
            pending.delete(data.id);
            clearTimeout(entry.timer);
            if (data.error) {
              entry.reject(new Error(data.error.message || data.error.code || "studio rpc error"));
            } else {
              entry.resolve(data.result);
            }
          }

          function rejectAllPending(reason) {
            for (const [, entry] of pending) {
              clearTimeout(entry.timer);
              entry.reject(new Error(reason));
            }
            pending.clear();
          }

          // `rhwp-event{event, payload}` — studio's only server->host push.
          // Version and session are checked like a response so a stale port or a
          // forged frame cannot inject picks.
          function dispatchEvent(data) {
            if (data.version !== EMBED_VERSION || typeof data.event !== "string") return;
            for (const listener of listeners) {
              try {
                listener(data.event, data.payload);
              } catch (error) {
                console.error("[rhwp-studio] host event listener failed", error);
              }
            }
          }

          function onEvent(listener) {
            listeners.add(listener);
            return () => listeners.delete(listener);
          }

          function connect() {
            if (state.connecting) return state.connecting;
            state.connecting = new Promise((resolve, reject) => {
              const attemptPorts = [];
              let retryTimer = null;
              let deadlineTimer = null;

              const stop = () => {
                if (retryTimer != null) clearInterval(retryTimer);
                if (deadlineTimer != null) clearTimeout(deadlineTimer);
                retryTimer = null;
                deadlineTimer = null;
              };
              const closeLosers = (winner) => {
                for (const port of attemptPorts) {
                  if (port === winner) continue;
                  port.onmessage = null;
                  try {
                    port.close();
                  } catch (_) {
                    // Already closed by studio's own releasePort.
                  }
                }
              };

              const attempt = () => {
                if (state.destroyed) return;
                const target = resolveWindow();
                if (!target) return;
                const channel = new MessageChannel();
                const port = channel.port1;
                attemptPorts.push(port);
                port.onmessage = ({ data }) => {
                  if (!data || data.sessionId !== sessionId) return;
                  if (data.type === "rhwp-connected") {
                    stop();
                    state.port = port;
                    state.capabilities = Array.isArray(data.capabilities)
                      ? data.capabilities.map(String)
                      : [];
                    closeLosers(port);
                    resolve(port);
                    return;
                  }
                  if (data.type === "rhwp-connect-error") {
                    stop();
                    closeLosers(null);
                    reject(new Error((data.error && data.error.message) || "studio rejected the embed handshake"));
                    return;
                  }
                  if (data.type === "rhwp-response") settle(data);
                  if (data.type === "rhwp-event") dispatchEvent(data);
                };
                port.start();
                // Same-origin bundle, so the exact origin is the tightest
                // targetOrigin available; studio additionally requires an
                // http/https parent origin (isUsableParentOrigin).
                target.postMessage(
                  {
                    type: "rhwp-connect",
                    version: EMBED_VERSION,
                    sessionId,
                    capabilities: EMBED_CAPABILITIES
                  },
                  window.location.origin,
                  [channel.port2]
                );
              };

              deadlineTimer = setTimeout(() => {
                stop();
                closeLosers(null);
                reject(new Error("rhwp-studio embed handshake timed out"));
              }, CONNECT_TIMEOUT_MS);
              retryTimer = setInterval(attempt, CONNECT_RETRY_MS);
              attempt();
            });
            state.connecting.catch(() => {
              state.connecting = null;
            });
            return state.connecting;
          }

          function hasCapability(name) {
            return state.capabilities.indexOf(name) >= 0;
          }

          async function call(method, params, transfer) {
            if (
              !EMBED_METHODS.includes(method)
              && !DOC_OPS_METHODS.includes(method)
              && !DOC_RECTS_METHODS.includes(method)
              && !DOC_ELEMENTS_METHODS.includes(method)
              && !HOST_EVENTS_METHODS.includes(method)
            ) {
              throw new Error(`embed protocol v1 routes no method: ${method}`);
            }
            const port = await connect();
            if (DOC_OPS_METHODS.includes(method) && !hasCapability(DOC_OPS_CAPABILITY)) {
              throw new Error(
                `${method} needs the ${DOC_OPS_CAPABILITY} capability, which the connected rhwp-studio bundle does not advertise`
              );
            }
            if (DOC_RECTS_METHODS.includes(method) && !hasCapability(DOC_RECTS_CAPABILITY)) {
              throw new Error(
                `${method} needs the ${DOC_RECTS_CAPABILITY} capability, which the connected rhwp-studio bundle does not advertise`
              );
            }
            if (DOC_ELEMENTS_METHODS.includes(method) && !hasCapability(DOC_ELEMENTS_CAPABILITY)) {
              throw new Error(
                `${method} needs the ${DOC_ELEMENTS_CAPABILITY} capability, which the connected rhwp-studio bundle does not advertise`
              );
            }
            if (HOST_EVENTS_METHODS.includes(method) && !hasCapability(HOST_EVENTS_CAPABILITY)) {
              throw new Error(
                `${method} needs the ${HOST_EVENTS_CAPABILITY} capability, which the connected rhwp-studio bundle does not advertise`
              );
            }
            const id = state.nextId;
            state.nextId = id + 1;
            return new Promise((resolve, reject) => {
              const timer = setTimeout(() => {
                pending.delete(id);
                reject(new Error(`rhwp-studio rpc timeout: ${method}`));
              }, CALL_TIMEOUT_MS);
              pending.set(id, { resolve, reject, timer });
              const envelope = {
                type: "rhwp-request",
                version: EMBED_VERSION,
                sessionId,
                id,
                method,
                params: params || {}
              };
              if (transfer && transfer.length > 0) {
                port.postMessage(envelope, transfer);
              } else {
                port.postMessage(envelope);
              }
            });
          }

          function destroy() {
            state.destroyed = true;
            rejectAllPending("rhwp-studio embed torn down");
            listeners.clear();
            if (state.port) {
              state.port.onmessage = null;
              try {
                state.port.close();
              } catch (_) {
                // Port already released by studio.
              }
            }
            state.port = null;
            state.connecting = null;
          }

          return { state, connect, call, hasCapability, onEvent, destroy };
        }

        function createSession(hook) {
          const frame = hook.el.querySelector("[data-role='rhwp-studio-frame']");
          const transport = createTransport(() => frame && frame.contentWindow);
          const state = transport.state;
          const connect = transport.connect;
          const call = transport.call;
          const hasCapability = transport.hasCapability;
          // Element-picker arming, mirrored from the host bridge's dataset. Kept
          // beside the session (not on the hook) like every other field here.
          const picker = { enabled: false, subscribed: false, releaseEvents: null };

          function canvasState() {
            return readCanvasState(hook.el);
          }

          function documentId() {
            return canvasState().documentId || null;
          }

          function documentFormat() {
            return (canvasState().localDocumentFormat || "hwp").toLowerCase();
          }

          function documentFileName() {
            const path = canvasState().documentPath || "";
            const base = path.split("/").filter(Boolean).pop();
            return base || `document.${documentFormat()}`;
          }

          // The LiveView fans engine events out to every canvas hook; only the
          // one bound to the routed document may answer (the server side of the
          // same guard is BrowserBridge's `expected_document_id`).
          function matchesDocument(payload) {
            const own = documentId();
            const incoming = payload && payload.document_id;
            if (!incoming || !own) return true;
            return incoming === own;
          }

          async function loadDocument(payload) {
            const url = payload && payload.url;
            if (!url) return false;
            if (state.loadedUrl === url && payload.force !== true) return true;
            const response = await fetch(url, { credentials: "same-origin" });
            if (!response.ok) throw new Error(`document fetch failed: ${response.status}`);
            const buffer = await response.arrayBuffer();
            await call("ready");
            // The buffer rides the transfer list, so the bytes are moved into
            // the studio realm instead of copied; nothing here touches them
            // afterwards (the local view is detached by the post).
            const result = await call(
              "loadFile",
              {
                data: new Uint8Array(buffer),
                fileName: documentFileName(),
                skipUnsavedGuard: true,
                suppressDialogs: true
              },
              [buffer]
            );
            state.loadedUrl = url;
            return result;
          }

          // doc.save / toolbar save: export from studio, hand the bytes to the
          // LiveView over the octet channel, then tell studio the host persisted
          // them so it can drop its autosave draft. `notifySaved` runs on the
          // octet ack (the server has the bytes) rather than on the export, so a
          // failed transfer keeps studio's recovery draft alive.
          async function exportForSave() {
            const format = documentFormat();
            const method = format === "hwpx" ? "exportHwpx" : "exportHwp";
            const exported = await call(method);
            const bytes = exported instanceof Uint8Array ? exported : new Uint8Array(exported);
            const uploaded = await octet.upload(hook, bytes);
            try {
              await call("notifySaved", { fileName: documentFileName() });
            } catch (error) {
              console.log("[rhwp-studio] notifySaved failed", error);
            }
            return Object.assign({ format }, uploaded);
          }

          // Every doc-ops verb goes through here first: it is the ONE place the
          // advertised capability is checked, so an older bundle degrades to the
          // documented `embed_rpc_gap:<verb>` error instead of a timeout on an
          // unknown method.
          async function requireDocOps(verb) {
            await connect();
            if (hasCapability(DOC_OPS_CAPABILITY)) return;
            throw new Error(`embed_rpc_gap:${verb}: ${EMBED_RPC_GAPS[verb]}`);
          }

          function requireRef(raw, verb) {
            const ref = parseHostRef(raw);
            if (!ref) {
              throw new Error(
                `${verb} requires a ref {section,paragraph,offset[,cell]} (from doc.find): ${refLabel(raw)}`
              );
            }
            return ref;
          }

          // ── doc.read ─────────────────────────────────────────────────────────
          // docRead answers one ref. The neighbourhood the host asks for is
          // rebuilt from N cheap same-realm reads rather than a section outline,
          // so a paragraph deep in a long section costs the window, not the
          // section.
          async function verbRead(payload) {
            const opts = (payload && payload.opts) || {};
            const raw = opts.ref;
            if (raw == null || raw === "") throw new Error("doc.read requires ref from doc.find");
            const ref = requireRef(raw, "doc.read");
            const nearby = opts.nearby || {};
            const before = boundedInt(nearby.before, 2);
            const after = boundedInt(nearby.after, 2);
            const target = await call("docRead", { ref: wireRef(ref) });
            const elements = [];
            if (ref.cell) {
              elements.push(readElement(ref, target));
            } else {
              const first = Math.max(0, ref.paragraph - before);
              for (let paragraph = first; paragraph <= ref.paragraph + after; paragraph += 1) {
                if (paragraph === ref.paragraph) {
                  elements.push(readElement(ref, target));
                  continue;
                }
                const neighbour = { section: ref.section, paragraph, offset: 0, length: null, cell: null };
                try {
                  const read = await call("docRead", { ref: wireRef(neighbour) });
                  elements.push(readElement(neighbour, read));
                } catch (_) {
                  // Past the first/last paragraph of the section; the window is
                  // simply shorter there.
                }
              }
            }
            const out = {
              ref: refLabel(raw),
              target: readElement(ref, target),
              elements,
              text: elements.map((element) => element.text || "").join("\n")
            };
            if (ref.cell) {
              out.note =
                "row/column context is unavailable on this arm: doc-ops-v1 routes no table-cell enumeration (WasmBridge.enumerateElements)";
            }
            return out;
          }

          function readElement(ref, read) {
            return {
              ref: refJson(ref),
              text: (read && read.text) || "",
              type: ref.cell ? "cell" : "paragraph"
            };
          }

          // ── doc.find ─────────────────────────────────────────────────────────
          async function verbFind(payload) {
            const params = payload || {};
            if (Array.isArray(params.patterns)) {
              const results = [];
              for (const pattern of params.patterns) {
                results.push(await findOne(pattern, params));
              }
              return { results };
            }
            return findOne(params.pattern, params);
          }

          async function findOne(pattern, params) {
            const discovery =
              params.all === true ||
              params.regex === true ||
              (typeof params.type === "string" && params.type !== "");
            if (discovery) {
              throw new Error(
                "embed_rpc_gap:find: discovery mode (all/regex/type) enumerates every element including empty cells, which needs WasmBridge.enumerateElements; doc-ops-v1 routes only the literal docFind"
              );
            }
            const query = pattern == null ? "" : String(pattern);
            if (query === "") {
              throw new Error("doc.find requires a non-empty pattern (doc-ops-v1 docFind rejects an empty query)");
            }
            const request = {
              query,
              caseSensitive: params.case_sensitive === true,
              includeCells: true
            };
            if (Number.isSafeInteger(params.limit) && params.limit > 0) request.limit = params.limit;
            const found = await call("docFind", request);
            const hits = Array.isArray(found && found.hits) ? found.hits : [];
            const matches = hits.map((hit) => {
              const ref = hitToRef(hit);
              const match = { ref: refJson(ref), text: query };
              if (ref.cell) match.table_cell = true;
              if (Number.isSafeInteger(hit.length)) match.length = hit.length;
              return match;
            });
            const out = { pattern: query, matches };
            if (found && found.truncated) out.truncated = true;
            return out;
          }

          // ── doc.get ──────────────────────────────────────────────────────────
          async function verbGet(payload) {
            const params = payload || {};
            if (Array.isArray(params.refs)) {
              const results = [];
              for (const raw of params.refs) {
                try {
                  results.push(Object.assign({ ref: refLabel(raw) }, await getOne(raw)));
                } catch (error) {
                  results.push({ ref: refLabel(raw), error: describeError(error) });
                }
              }
              return { results };
            }
            return getOne(params.ref);
          }

          async function getOne(raw) {
            if (raw == null || raw === "") return call("docGet", {});
            return call("docGet", { ref: wireRef(requireRef(raw, "doc.get")) });
          }

          // ── elements: the doc VFS projection's IR source ──────────────────────
          // The mount projects a WHOLE document, so it needs every addressable
          // node at once — the seam the deleted `ehwp` NIF served with
          // `enumerate_elements`. doc-ops-v1 has NO element enumerator (there is
          // no `WasmBridge.enumerateElements` upstream), so this rebuilds one
          // from the two bulk primitives it does route: `docGet {}` for the
          // section/paragraph census and `docRead {section}` for each section's
          // paragraph outline, with a per-ref read for any tail the outline's
          // 2000-paragraph cap left off.
          //
          // COVERAGE — stated in the reply because the host must never present
          // it as complete. BODY PARAGRAPHS ONLY. Table cells, pictures, text
          // boxes and every other CONTROL are invisible through THIS verb, and
          // nothing reachable over doc-ops-v1 can even count them: rhwp's parser
          // advances `ctrl_idx` for an extended control WITHOUT pushing a
          // placeholder char into `para.text`, so over `docRead` a paragraph
          // holding a table is indistinguishable from an empty one.
          //
          // The ENGINE is not the limit — the transport is. rhwp_core already
          // exports `getControlTextPositions` (one entry per control, i.e. a
          // per-paragraph control count) and `getPageControlLayout` (types and
          // locates table/image/shape with a full cells[] grid), and carries a
          // whole DocLang 0.6 exporter in `src/doclang/` that is already compiled
          // into rhwp_bg.wasm. None of it is routed through the embed RPC, whose
          // 9 verbs (embed/rpc-router.ts) contain no enumerator. Closing the gap
          // is a new gated capability (doc-elements-v1) carrying an element
          // enumerator over the SIR — see "Remaining, in priority order" item 0
          // in docs/plans/2026-07-26-doclang-engine-migration.md.
          const ELEMENTS_OUTLINE_LIMIT = 2000;

          async function verbElements() {
            // Prefer the real enumerator when the connected bundle carries it.
            // It walks the DocLang SIR, so tables/pictures/text boxes come back
            // in document order with their refs — the coverage this arm reports
            // as missing below. Gated, so an older installed dist simply falls
            // through to the paragraph census and keeps saying so.
            if (hasCapability(DOC_ELEMENTS_CAPABILITY)) {
              const enumerated = await call("docElements", {});
              const list = Array.isArray(enumerated)
                ? enumerated
                : (enumerated && Array.isArray(enumerated.elements) ? enumerated.elements : null);
              // A malformed/empty reply must NOT be presented as a complete
              // projection: the write-back diff would read every real paragraph
              // as deleted text and lower it to real deletions.
              if (list && list.length) {
                return { elements: list, coverage: "full_ir", complete: true, note: null };
              }
            }
            const info = await call("docGet", {});
            const sections = Array.isArray(info && info.sections) ? info.sections : [];
            const elements = [];
            for (const entry of sections) {
              const section = Number.isSafeInteger(entry && entry.section) ? entry.section : 0;
              const total = Number.isSafeInteger(entry && entry.paragraphCount)
                ? entry.paragraphCount
                : 0;
              if (total <= 0) continue;
              const outline = await call("docRead", { section, limit: ELEMENTS_OUTLINE_LIMIT });
              const paragraphs = Array.isArray(outline && outline.paragraphs) ? outline.paragraphs : [];
              for (const para of paragraphs) {
                elements.push(paragraphElement(section, para.paragraph, para.text));
              }
              // The outline is capped upstream and always starts at paragraph 0,
              // so a long section has to be finished one ref at a time. A SHORT
              // enumeration is the one failure this must never paper over: the
              // write-back diff would read the missing tail as deleted text and
              // lower it to real deletions.
              for (let paragraph = paragraphs.length; paragraph < total; paragraph += 1) {
                const read = await call("docRead", {
                  ref: wireRef({ section, paragraph, offset: 0, length: null, cell: null })
                });
                elements.push(paragraphElement(section, paragraph, read && read.text));
              }
            }
            return {
              elements,
              coverage: "body_paragraphs",
              complete: false,
              note:
                "doc-ops-v1 exposes no element enumerator, so this projection carries body " +
                "paragraphs only: table cells, pictures and text boxes are absent. Their text " +
                "is NOT in this buffer and editing it here is not possible; use doc.find / " +
                "doc.read to reach table-cell text."
            };
          }

          // The node shape `Doclang.Adapter.Hwp` consumes. Exactly three keys:
          // every OTHER scalar field would be lowered into a `<custom>` entry and
          // show up as noise in the mounted XML.
          function paragraphElement(section, paragraph, text) {
            return {
              type: "paragraph",
              text: typeof text === "string" ? text : "",
              ref: { section, paragraph, offset: 0 }
            };
          }

          // ── doc.edit ─────────────────────────────────────────────────────────
          // The host's verbs are richer than doc-ops-v1's three primitives, so
          // each is RESOLVED first (a query becomes an offset, "end" becomes a
          // ref, a cell's paragraph count is read) and only then sent as one
          // docEdit batch. Resolving everything before mutating anything is what
          // keeps the offsets consistent: doc-ops applies in reverse document
          // order, so no applied op can move a ref another op already computed.
          async function buildEditPlan(rawOps) {
            const plan = [];
            for (let index = 0; index < rawOps.length; index += 1) {
              const rawOp = rawOps[index];
              const label = refLabel(rawOp && rawOp.ref);
              try {
                const resolved = await resolveEditOp(rawOp);
                plan.push({ index, ref: label, ops: resolved.ops, evidence: resolved.evidence });
              } catch (error) {
                plan.push({ index, ref: label, error: describeError(error) });
              }
            }
            return plan;
          }

          function flattenPlan(plan) {
            const ops = [];
            const owners = [];
            for (const entry of plan) {
              if (entry.error) continue;
              for (const op of entry.ops) {
                owners.push(entry);
                ops.push(op);
              }
            }
            return { ops, owners };
          }

          // Fold doc-ops' per-doc-op results back onto the HOST ops that produced
          // them (one host op can expand into several, e.g. a global replace or a
          // multi-paragraph set_cell), so `applied`/`failed`/`results` still count
          // what the agent submitted.
          function foldPlan(plan, owners, batch) {
            const raw = batch && Array.isArray(batch.results) ? batch.results : [];
            const totals = new Map();
            owners.forEach((entry, position) => {
              const result = raw[position] || { ok: false, error: "no result returned" };
              const acc = totals.get(entry) || { applied: 0, failed: 0, errors: [] };
              if (result.ok) acc.applied += 1;
              else {
                acc.failed += 1;
                acc.errors.push(result.error || "unknown_error");
              }
              totals.set(entry, acc);
            });
            const results = [];
            let applied = 0;
            let failed = 0;
            for (const entry of plan) {
              if (entry.error) {
                failed += 1;
                results.push({ ref: entry.ref, error: entry.error });
                continue;
              }
              const acc = totals.get(entry) || { applied: 0, failed: 0, errors: [] };
              if (acc.failed > 0) {
                failed += 1;
                results.push({ ref: entry.ref, error: acc.errors.join("; ") });
              } else {
                applied += 1;
                results.push(Object.assign({ ref: entry.ref, ok: true }, entry.evidence(acc)));
              }
            }
            return { ok: failed === 0, applied, failed, results };
          }

          async function runEditPlan(plan) {
            const flat = flattenPlan(plan);
            const batch = flat.ops.length > 0 ? await call("docEdit", { ops: flat.ops }) : null;
            return foldPlan(plan, flat.owners, batch);
          }

          async function verbEdit(payload) {
            const params = payload || {};
            if (Array.isArray(params.ops)) {
              if (params.ops.length === 0) throw new Error("edit batch requires a non-empty 'ops' array");
              return runEditPlan(await buildEditPlan(params.ops));
            }
            const plan = await buildEditPlan([params.op]);
            const folded = await runEditPlan(plan);
            const only = folded.results[0] || {};
            if (only.error) throw new Error(only.error);
            // The single-op reply is the per-op EVIDENCE (replaced/inserted/...),
            // which `Doc.Tools.browser_write_evidence` passes through to the
            // agent; `ref` is plumbing and is filtered there anyway.
            const evidence = { ok: true };
            for (const key of Object.keys(only)) {
              if (key !== "ref") evidence[key] = only[key];
            }
            return evidence;
          }

          async function resolveEditOp(rawOp) {
            if (!rawOp || typeof rawOp !== "object") throw new Error("edit op must be an object");
            const verb = String(rawOp.op || "");
            if (verb === "insert_text") return resolveInsertText(rawOp);
            if (verb === "replace_text") return resolveReplaceText(rawOp);
            if (verb === "delete_range") return resolveDeleteRange(rawOp);
            if (verb === "set_cell") return resolveSetCell(rawOp);
            if (verb === "delete_paragraph") return resolveDeleteParagraph(rawOp);
            if (verb === "insert_picture") return resolveInsertPicture(rawOp);
            if (verb === "delete_node") return resolveDeleteNode(rawOp);
            throw new Error(
              `embed_rpc_gap:edit:${verb || "unknown"}: doc-ops-v1 routes insert_text/replace_text/delete_range/set_cell/delete_paragraph/insert_picture/delete_node; ${verb || "that verb"} has no method`
            );
          }

          async function resolveInsertText(rawOp) {
            const text = rawOp.text == null ? "" : String(rawOp.text);
            if (!text) throw new Error("insert_text requires non-empty 'text'");
            const ref = rawOp.ref === "end" ? await resolveEndRef() : requireRef(rawOp.ref, "insert_text");
            return {
              ops: [{ op: "insert_text", ref: wireRef(ref), text }],
              evidence: () => ({ inserted: text.length })
            };
          }

          // "end" -> an appendable position at the document tail. docGet with no
          // ref reports every section's paragraph count; a second docGet reads the
          // last paragraph's length.
          async function resolveEndRef() {
            const info = await call("docGet", {});
            const sections = Array.isArray(info && info.sections) ? info.sections : [];
            const last = sections.length > 0 ? sections[sections.length - 1] : { section: 0, paragraphCount: 0 };
            const paragraph = Math.max(0, (last.paragraphCount || 0) - 1);
            const ref = { section: last.section || 0, paragraph, offset: 0, length: null, cell: null };
            const paragraphInfo = await call("docGet", { ref: wireRef(ref) });
            ref.offset = Number.isSafeInteger(paragraphInfo && paragraphInfo.length) ? paragraphInfo.length : 0;
            return ref;
          }

          // `replace_text` is {query, replacement} here and positional
          // {ref, length, text} there, so the query is turned into an offset:
          // inside the ref'd paragraph/cell when it is there, else globally —
          // which keeps the legacy "matches N places" guard and `all: true`.
          async function resolveReplaceText(rawOp) {
            const query = rawOp.query == null ? "" : String(rawOp.query);
            if (!query) throw new Error("replace_text requires a non-empty query");
            if (rawOp.replacement == null) {
              throw new Error(
                "replace_text requires a 'replacement' field (the field is 'replacement', not 'text'/'new'; to delete text use delete_range)"
              );
            }
            const replacement = String(rawOp.replacement);
            const ref = parseHostRef(rawOp.ref);
            if (ref) {
              const read = await call("docRead", { ref: wireRef(ref, 0) });
              const index = String((read && read.text) || "").indexOf(query);
              if (index >= 0) {
                return {
                  ops: [{ op: "replace_text", ref: wireRef(ref, index), length: query.length, text: replacement }],
                  evidence: () => ({ replaced: 1 })
                };
              }
            }
            const found = await call("docFind", { query, caseSensitive: true, includeCells: true });
            const hits = Array.isArray(found && found.hits) ? found.hits : [];
            if (hits.length === 0) {
              throw new Error("replace_text: no match for query (it must be the document's exact current text)");
            }
            if (hits.length > 1 && rawOp.all !== true) {
              throw new Error(
                `replace_text: query matches ${hits.length} places; pass a ref to target one, use a longer/unique query, or pass all:true to replace every match`
              );
            }
            const ops = hits.map((hit) => {
              const hitRef = hitToRef(hit);
              return {
                op: "replace_text",
                ref: wireRef(hitRef),
                length: Number.isSafeInteger(hit.length) ? hit.length : query.length,
                text: replacement
              };
            });
            return { ops, evidence: (acc) => ({ replaced: acc.applied }) };
          }

          async function resolveDeleteRange(rawOp) {
            const ref = requireRef(rawOp.ref, "delete_range");
            let count = Number.isSafeInteger(rawOp.count) ? rawOp.count : null;
            if (count === null) {
              const read = await call("docRead", { ref: wireRef(ref) });
              const length = Number.isSafeInteger(read && read.paragraphLength) ? read.paragraphLength : 0;
              count = Math.max(0, length - ref.offset);
            }
            if (count <= 0) throw new Error("delete_range: nothing to delete (count must be > 0)");
            return {
              ops: [{ op: "delete_range", ref: wireRef(ref), count }],
              evidence: () => ({ deleted: count })
            };
          }

          // Removing a paragraph BREAK. `delete_range` cannot: it is intra-paragraph
          // by construction and used to answer ok:true for a request clamped to
          // nothing. Upstream now refuses the over-run and routes this verb to the
          // engine's `deleteParagraph`.
          async function resolveDeleteParagraph(rawOp) {
            const ref = requireRef(rawOp.ref, "delete_paragraph");
            return {
              ops: [{ op: "delete_paragraph", ref: wireRef(ref) }],
              evidence: (result) => ({
                paragraphsRemoved: (result && result.paragraphCountBefore != null && result.paragraphCount != null)
                  ? result.paragraphCountBefore - result.paragraphCount
                  : 1
              })
            };
          }

          // The bytes ride INLINE as a base64 data URI. The engine has no filesystem
          // and resolves a bare src as a URL, so a host path can never load; an
          // http(s) fetch would resolve differently per origin/CSP; and a
          // `bin<NNNN>.<ext>` is a BinData label inside the document, not an address.
          async function resolveInsertPicture(rawOp) {
            const ref = requireRef(rawOp.ref, "insert_picture");
            const src = String(rawOp.src == null ? "" : rawOp.src);
            if (!src.startsWith("data:image/") || !src.includes(";base64,")) {
              throw new Error(
                `insert_picture: src must be a base64 data URI (data:image/<type>;base64,…), got ${JSON.stringify(src.slice(0, 48))}`
              );
            }
            const op = { op: "insert_picture", ref: wireRef(ref), src };
            for (const key of ["width", "height", "naturalWidth", "naturalHeight", "description"]) {
              if (rawOp[key] != null) op[key] = rawOp[key];
            }
            return {
              ops: [op],
              evidence: (result) => ({
                mime: result && result.mime,
                byteLength: result && result.byteLength,
                control: result && result.control
              })
            };
          }

          // Only pictures are routed; tables/shapes/equations exist in the engine
          // but have no verb, and refuse by name rather than silently doing nothing.
          async function resolveDeleteNode(rawOp) {
            const ref = requireRef(rawOp.ref, "delete_node");
            return {
              ops: [{ op: "delete_node", ref: wireRef(ref) }],
              evidence: (result) => ({ type: result && result.type, mime: result && result.mime })
            };
          }

          // set_cell replaces a cell's whole content. doc-ops-v1 has no
          // mergeParagraphInCell, so one replace per existing cell paragraph is
          // the exact lowering — the LAST one absorbs any surplus lines, because
          // doc-ops' in-cell insert splits on newlines and the reverse-order
          // batch applies the highest cellPara first.
          async function resolveSetCell(rawOp) {
            const ref = requireRef(rawOp.ref, "set_cell");
            if (!ref.cell) throw new Error("set_cell requires a CELL ref (doc.find text inside the cell)");
            const lines = splitLines(rawOp.text == null ? "" : String(rawOp.text));
            const info = await call("docGet", { ref: wireCellParaRef(ref, 0, 0) });
            const paragraphCount =
              Number.isSafeInteger(info && info.paragraphCount) && info.paragraphCount > 0
                ? info.paragraphCount
                : 1;
            if (lines.length < paragraphCount) {
              throw new Error(
                `embed_rpc_gap:edit:set_cell: the cell holds ${paragraphCount} paragraphs and the new text has ${lines.length} lines; collapsing them needs WasmBridge.mergeParagraphInCell, which doc-ops-v1 does not route`
              );
            }
            const ops = [];
            for (let cellPara = 0; cellPara < paragraphCount; cellPara += 1) {
              const cellRef = wireCellParaRef(ref, cellPara, 0);
              const read = await call("docRead", { ref: cellRef });
              const length = Number.isSafeInteger(read && read.paragraphLength) ? read.paragraphLength : 0;
              const text = cellPara === paragraphCount - 1 ? lines.slice(cellPara).join("\n") : lines[cellPara];
              ops.push({ op: "replace_text", ref: cellRef, length, text });
            }
            return { ops, evidence: () => ({ cellParaCount: lines.length }) };
          }

          // ── doc.set ──────────────────────────────────────────────────────────
          async function verbSet(payload) {
            const params = payload || {};
            if (Array.isArray(params.sets)) {
              return runSetBatch(params.sets);
            }
            const folded = await runSetBatch([{ ref: params.ref, props: params.props }]);
            const only = folded.results[0] || {};
            if (only.error) throw new Error(only.error);
            return { ok: true };
          }

          async function runSetBatch(rawSets) {
            const plan = [];
            for (let index = 0; index < rawSets.length; index += 1) {
              const rawSet = rawSets[index] || {};
              const label = refLabel(rawSet.ref);
              try {
                plan.push({ index, ref: label, ops: [resolveSet(rawSet)], evidence: () => ({}) });
              } catch (error) {
                plan.push({ index, ref: label, error: describeError(error) });
              }
            }
            const flat = flattenPlan(plan);
            const batch = flat.ops.length > 0 ? await call("docSet", { sets: flat.ops }) : null;
            return foldPlan(plan, flat.owners, batch);
          }

          // `props.kind` chooses the property space. doc-ops-v1 routes
          // applyCharFormat and setCellProperties; para/picture/field property
          // sets have no method and say so by name.
          function resolveSet(rawSet) {
            const ref = requireRef(rawSet.ref, "set");
            const props = rawSet.props;
            if (!props || typeof props !== "object") throw new Error("set requires a 'props' object");
            const rest = {};
            let kind = null;
            for (const key of Object.keys(props)) {
              if (key === "kind") {
                kind = props[key] == null ? null : String(props[key]);
                continue;
              }
              rest[key] = props[key];
            }
            if (Object.keys(rest).length === 0) throw new Error("set requires at least one property in 'props'");
            const target = kind || (ref.cell ? "cell" : "char");
            if (target === "cell") {
              if (!ref.cell) {
                throw new Error("set kind:cell needs a cell ref (doc.find a cell, then set its BackgroundColor)");
              }
              return { ref: wireRef(ref), props: rest, target: "cell" };
            }
            if (target === "char") {
              const entry = { ref: wireRef(ref), props: translateCharProps(rest), target: "char" };
              if (Number.isSafeInteger(ref.length) && ref.length > 0) entry.length = ref.length;
              return entry;
            }
            throw new Error(
              `embed_rpc_gap:set:${target}: doc-ops-v1 routes applyCharFormat (kind:char) and setCellProperties (kind:cell); kind:${target} needs applyParaFormat/setPictureProperties/setFieldValue, which it does not route`
            );
          }

          // ── VFS transaction ──────────────────────────────────────────────────
          // One reversible unit: resolve + apply + export inside docVfsWrite, hand
          // the bytes to the LiveView over the octet channel, then commit and
          // finalize on the server's own boundary. A failure after the write must
          // roll the engine back, or its write lock (`document_write_in_progress`)
          // would outlive the turn.
          async function verbVfsWrite(payload) {
            const params = payload || {};
            const editId = String(params.edit_id || params.editId || "");
            if (!editId) throw new Error("vfs_write requires edit_id");
            const format = documentFormat();
            const rawOps = Array.isArray(params.ops) ? params.ops : [];
            const rawSets = Array.isArray(params.sets) ? params.sets : [];

            const plan = await buildEditPlan(rawOps);
            const rejected = plan.filter((entry) => entry.error);
            if (rejected.length > 0) {
              throw new Error(`edit: ${rejected.map((entry) => entry.error).slice(0, 3).join("; ")}`);
            }
            const flat = flattenPlan(plan);
            const sets = rawSets.map((rawSet) => resolveSet(rawSet || {}));

            // rpc-router.ts validates `ops`/`sets` with asOptionalList: absent is
            // fine, EMPTY is an error. A DocLang write-back routinely carries only
            // one of the two, so an empty array must be omitted, not sent.
            // `format` is the opposite kind of field: doc-ops would default to the
            // document's own source format anyway, but the host names it so the
            // exported container is the one the SOURCE FILE already has.
            const request = { editId, format };
            if (flat.ops.length > 0) request.ops = flat.ops;
            if (sets.length > 0) request.sets = sets;
            const result = await call("docVfsWrite", request);
            try {
              // doc-ops echoes the container it exported. A bundle predating the
              // format selector omits it and always exported HWP, so a missing
              // echo is read as "hwp" — and refused for any other source, since
              // those bytes go straight over the source file.
              const exported = (result && result.format) || "hwp";
              if (exported !== format) {
                throw new Error(
                  `embed_rpc_gap:vfs_write: docVfsWrite exported ${exported} for a .${format} source; the installed studio bundle has no format-aware export`
                );
              }
              const raw = result && result.bytes;
              const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw || 0);
              const uploaded = await octet.upload(hook, bytes);
              return Object.assign({ format, edit_id: editId }, uploaded, {
                edit: foldPlan(plan, flat.owners, result && result.edit),
                set: normalizeBatch(result && result.set, rawSets.length),
                page_count: result && result.pageCount,
                byte_length: result && result.byteLength
              });
            } catch (error) {
              try {
                await call("docVfsRollback", { editId });
              } catch (rollbackError) {
                console.log("[rhwp-studio] rollback after failed vfs_write upload failed", rollbackError);
              }
              throw error;
            }
          }

          function normalizeBatch(batch, expected) {
            const results = batch && Array.isArray(batch.results) ? batch.results : [];
            return {
              ok: !batch || batch.ok !== false,
              applied: batch && Number.isSafeInteger(batch.applied) ? batch.applied : results.length,
              failed: batch && Number.isSafeInteger(batch.failed) ? batch.failed : 0,
              results: results.length > 0 ? results : new Array(expected).fill({ ok: true })
            };
          }

          // doc-ops answers camelCase; the host's VFS bookkeeping has always read
          // the legacy snake_case keys.
          function vfsState(result, editId) {
            const out = { ok: true, edit_id: editId };
            const map = {
              awaitingFinalize: "awaiting_finalize",
              alreadyCommitted: "already_committed",
              finalized: "finalized",
              alreadyFinalized: "already_finalized",
              rolledBack: "rolled_back",
              alreadyRolledBack: "already_rolled_back",
              cancelled: "cancellation_pending"
            };
            for (const key of Object.keys(map)) {
              if (result && result[key] === true) out[map[key]] = true;
            }
            return out;
          }

          function requireEditId(payload, verb) {
            const editId = String((payload && (payload.edit_id || payload.editId)) || "");
            if (!editId) throw new Error(`${verb} requires edit_id`);
            return editId;
          }

          // BrowserBridge verb -> embed RPC. `save` rides the export methods embed
          // v1 always had; every other verb rides doc-ops-v1 and fails with a
          // named gap when the connected bundle does not advertise it.
          async function runVerb(verb, payload) {
            if (verb === "save") return exportForSave(payload);
            if (!Object.prototype.hasOwnProperty.call(EMBED_RPC_GAPS, verb)) {
              throw new Error(`unsupported_verb:${verb}`);
            }
            await requireDocOps(verb);
            if (verb === "read") return verbRead(payload);
            if (verb === "find") return verbFind(payload);
            if (verb === "edit") return verbEdit(payload);
            if (verb === "set") return verbSet(payload);
            if (verb === "get") return verbGet(payload);
            if (verb === "elements") return verbElements(payload);
            if (verb === "vfs_write") return verbVfsWrite(payload);
            if (verb === "vfs_commit") {
              const editId = requireEditId(payload, "vfs_commit");
              return vfsState(await call("docVfsCommit", { editId }), editId);
            }
            if (verb === "vfs_finalize") {
              const editId = requireEditId(payload, "vfs_finalize");
              const result = vfsState(await call("docVfsFinalize", { editId }), editId);
              // The host has durably persisted these bytes, so studio may drop
              // its autosave draft — the same boundary `save` uses.
              try {
                await call("notifySaved", { fileName: documentFileName() });
              } catch (error) {
                console.log("[rhwp-studio] notifySaved after finalize failed", error);
              }
              return result;
            }
            const editId = requireEditId(payload, "vfs_rollback");
            return vfsState(await call("docVfsRollback", { editId }), editId);
          }

          // ── element picker ───────────────────────────────────────────────────
          // Arming subscribes to studio's `selection` push; disarming drops it, so
          // a document nobody is picking from costs nothing on the wire. The
          // subscription also dies with the port, hence the re-subscribe on every
          // arm rather than a once-per-mount call.
          async function setPickerEnabled(enabled) {
            picker.enabled = enabled === true;
            if (picker.enabled === picker.subscribed) return;
            await connect();
            if (!hasCapability(HOST_EVENTS_CAPABILITY)) {
              // An installed bundle predating host-events-v1 cannot push a pick.
              // Say so once, by name, instead of leaving a dead crosshair cursor.
              if (picker.enabled) {
                console.log(
                  `[rhwp-studio] element picking needs the ${HOST_EVENTS_CAPABILITY} capability, ` +
                    "which the connected rhwp-studio bundle does not advertise — rebuild and reinstall it"
                );
              }
              return;
            }
            await call("setEventSubscription", { events: picker.enabled ? ["selection"] : [] });
            picker.subscribed = picker.enabled;
          }

          // One studio `selection` push -> one composer chip. Only pointer picks
          // count: `caret` fires for keyboard motion and for the agent's own
          // edits, and neither is a user pointing at something.
          function handleSelectionEvent(selection) {
            if (!picker.enabled || !selection || selection.reason !== "pointer") return;
            const ref = pickRefFrom(selection);
            const encoded = encodeHwpRef(ref);
            if (!encoded) return;
            appendPickedElementToComposer({
              document: canvasState().documentPath || "",
              backend: "rhwp",
              format: documentFormat(),
              type: selection.kind === "cell" ? "table_cell" : "paragraph",
              ref: encoded,
              text: pickLabel(selection.text),
              hint: selection.kind === "cell" ? "table cell" : "paragraph",
              ir: {
                page: selection.page,
                kind: selection.kind,
                ref: ref,
                paragraph_length: selection.paragraphLength
              }
            });
          }

          function installPicker() {
            picker.releaseEvents = transport.onEvent((name, payload) => {
              if (name === "selection") handleSelectionEvent(payload);
            });
            const apply = () => {
              setPickerEnabled(documentElementPickerEnabled()).catch((error) => {
                console.log("[rhwp-studio] element picker subscription failed", error);
              });
            };
            document.addEventListener(PICKER_STATE_EVENT, apply);
            picker.releaseState = () => document.removeEventListener(PICKER_STATE_EVENT, apply);
            // The bridge broadcasts on mount, but this hook may mount after it.
            apply();
          }

          async function handleEngineCommand(payload) {
            const requestId = payload && payload.request_id;
            const verb = String((payload && payload.verb) || "");
            try {
              const result = await runVerb(verb, (payload && payload.payload) || {});
              hook.pushEvent("document.engine.operation.replied", {
                request_id: requestId,
                result: result && typeof result === "object" ? result : { ok: true }
              });
            } catch (error) {
              hook.pushEvent("document.engine.operation.replied", {
                request_id: requestId,
                error: describeError(error)
              });
            }
          }

          async function handleSaveCommand(payload) {
            const requestId = (payload && payload.request_id) || `save:${Date.now()}`;
            const id = (payload && payload.document_id) || documentId();
            try {
              const saved = await exportForSave();
              hook.pushEvent(
                "document.viewer.save_requested",
                Object.assign({ request_id: requestId, document_id: id }, saved)
              );
            } catch (error) {
              hook.pushEvent("document.viewer.save_requested", {
                request_id: requestId,
                document_id: id,
                error: describeError(error)
              });
            }
          }

          // Tell the LiveView whether this embed actually HOLDS the document
          // model. `document.viewer.ready` is what makes the LiveView call
          // `Workspace.Session.attach_viewer/3`, and that registration is the
          // ONLY thing that makes `Session.viewer/2` answer with this pid —
          // i.e. the entire browser arm, for reads (the VFS projection's
          // `elements`), for `doc.*`, and for VFS write-back.
          //
          // REGRESSION 2026-07-26: the legacy HWP canvas pushed this from its own
          // `notifyViewerState`; deleting that canvas dropped the push, and
          // nothing in this embed replaced it. Every viewed HWP therefore routed
          // to the SERVER arm — which has had no engine since the deps were
          // removed — so the mount could never project a document that was
          // sitting open on screen. The office arm kept its push and kept
          // working, which is exactly why the gap read as "HWP is unsupported".
          function notifyViewerState(ready) {
            const id = documentId();
            if (!id) return;
            try {
              hook.pushEvent(ready ? "document.viewer.ready" : "document.viewer.failed", {
                document_id: id
              });
            } catch (_) {
              // Disconnected socket — nothing to claim or relinquish.
            }
          }

          return {
            canvasState,
            connect,
            call,
            loadDocument,
            notifyViewerState,
            handleEngineCommand,
            handleSaveCommand,
            matchesDocument,
            installPicker,
            destroy() {
              if (picker.releaseState) picker.releaseState();
              if (picker.releaseEvents) picker.releaseEvents();
              picker.releaseState = null;
              picker.releaseEvents = null;
              transport.destroy();
            },
            state
          };
        }

        // ── mirror previews (the chat-rail cards) ──────────────────────────────
        // A mirror is an INERT picture of a document: `pointer-events-none`, no
        // toolbar, no caret, no agent verb ever routed to it. Giving each card its
        // own studio iframe would boot a whole engine per card — the bundle
        // carries a 24 MB `rhwp_bg.wasm` plus a 7 MB canvaskit — in a rail that
        // grows one card per committed edit. So every mirror on the page shares
        // ONE invisible studio instance and paints a page SVG from it: measured
        // on a real 35-page Korean document, `loadFile` 0.6 s + `getPageSvg`
        // 76 ms, and 1.1 s from card mount to painted page including the engine's
        // cold boot.
        //
        // The page rides an <img>, not innerHTML: an image executes no script and
        // inherits none of the host's CSS, and the engine writes per-cluster
        // `textLength`/`lengthAdjust`, so a substituted font changes glyph shapes
        // without moving the layout.
        const PREVIEW_IDLE_MS = 60000;
        const PREVIEW_IMAGE_CACHE_LIMIT = 8;
        const PREVIEW_HIGHLIGHT_PROBES = 4;

        // `${bytesUrl}|${highlightKey}#${page}` -> object URL, and bytesUrl ->
        // the {page, cacheKey} already chosen for it. Both survive the engine's
        // teardown, so a rail that scrolls a card back into view repaints
        // without booting anything. The highlight is part of the key because it
        // is now part of the IMAGE: two cards can share one committed snapshot
        // and mark different ranges of it.
        const previewImages = new Map();
        const previewPages = new Map();
        let previewRenderer = null;
        let previewHolders = 0;
        let previewBusy = 0;
        let previewIdleTimer = null;
        let previewChain = Promise.resolve();

        function acquirePreviewRenderer() {
          previewHolders += 1;
          if (previewIdleTimer !== null) {
            clearTimeout(previewIdleTimer);
            previewIdleTimer = null;
          }
          if (previewRenderer) return previewRenderer;
          const frame = document.createElement("iframe");
          frame.src = "/rhwp-studio/index.html";
          frame.title = "rhwp-studio preview renderer";
          frame.setAttribute("aria-hidden", "true");
          frame.setAttribute("tabindex", "-1");
          frame.setAttribute("data-role", "rhwp-studio-preview-renderer");
          // Transparent and 2px, but INSIDE the viewport and never
          // `display:none`. A frame the browser does not render has its timers
          // throttled to ~1 Hz, and studio's load path awaits a paint between
          // each of its ~7 progress steps: measured on a real Korean document,
          // the same `loadFile` took **9.3 s parked offscreen and 0.6 s here**
          // (0.27 s for a 4-page document). The engine work is ~1.4 s of that;
          // the rest was the throttle.
          frame.style.cssText =
            "position:fixed;left:0;bottom:0;width:2px;height:2px;border:0;opacity:0;pointer-events:none;z-index:-1";
          document.body.appendChild(frame);
          previewRenderer = {
            frame,
            transport: createTransport(() => frame.contentWindow),
            loadedUrl: null
          };
          return previewRenderer;
        }

        function schedulePreviewTeardown() {
          if (previewIdleTimer !== null || !previewRenderer) return;
          if (previewHolders > 0 || previewBusy > 0) return;
          previewIdleTimer = setTimeout(() => {
            previewIdleTimer = null;
            if (previewHolders > 0 || previewBusy > 0 || !previewRenderer) return;
            // Only the ENGINE is released; the rendered pages stay cached.
            previewRenderer.transport.destroy();
            previewRenderer.frame.remove();
            previewRenderer = null;
          }, PREVIEW_IDLE_MS);
        }

        function releasePreviewRenderer() {
          previewHolders = Math.max(0, previewHolders - 1);
          schedulePreviewTeardown();
        }

        function rememberPreviewImage(key, objectUrl) {
          previewImages.set(key, objectUrl);
          if (previewImages.size <= PREVIEW_IMAGE_CACHE_LIMIT) return;
          for (const [oldest, url] of previewImages) {
            // Never revoke a blob a card is still showing — the <img> would have
            // nothing to re-decode from on the next layout.
            if (document.querySelector(`[data-role='rhwp-studio-preview-page'][src='${url}']`)) {
              continue;
            }
            previewImages.delete(oldest);
            URL.revokeObjectURL(url);
            break;
          }
        }

        // Where the edit is: which page to draw, and the rects to draw ON it.
        //
        // A highlight names a ref (`{section,paragraph,…}` or `hwp:s0/p7`) and/or
        // the text that was written. `docFind` recovers the ref from the text when
        // there is none; `docRects` (doc-rects-v1) then answers the selection
        // rectangles in the SAME page-px space `getPageSvg`'s viewBox uses, so the
        // overlay needs no scale math. Falls back to page 1 with no rects — a
        // preview never goes blank because a ref went stale.
        async function resolvePreviewGeometry(renderer, highlights) {
          const empty = { page: 0, rects: [] };
          if (!renderer.transport.hasCapability(DOC_OPS_CAPABILITY)) return empty;
          const canMeasure = renderer.transport.hasCapability(DOC_RECTS_CAPABILITY);
          let page = null;
          const rects = [];
          for (const highlight of highlights.slice(0, PREVIEW_HIGHLIGHT_PROBES)) {
            try {
              const ref = await previewRefForHighlight(renderer, highlight);
              if (!ref) continue;
              if (!canMeasure) {
                // No geometry from this bundle: still choose the right page.
                if (page !== null) continue;
                const found = await previewPageForRef(renderer, ref);
                if (Number.isSafeInteger(found)) page = found;
                continue;
              }
              const range = previewHighlightRange(highlight, ref);
              const measured = await renderer.transport.call("docRects", {
                ref: wireRef(ref, range.offset),
                length: range.length
              });
              if (page === null && Number.isSafeInteger(measured && measured.page)) {
                page = measured.page;
              }
              for (const rect of (measured && measured.rects) || []) rects.push(rect);
            } catch (error) {
              // A ref the committed document no longer has, or a query that no
              // longer matches. Try the next highlight — but SAY SO. Swallowing
              // this silently made "the preview has no highlight" impossible to
              // tell apart from "this bundle cannot measure", "the ref went
              // stale" and "docRects threw", which are three different bugs.
              console.log("[rhwp preview] highlight geometry failed:", error && error.message);
            }
          }
          if (!canMeasure) {
            console.log(
              `[rhwp preview] connected bundle does not advertise ${DOC_RECTS_CAPABILITY};` +
                " showing the right page with NO highlight rectangles"
            );
          } else if (page !== null && rects.length === 0) {
            console.log(
              "[rhwp preview] docRects returned no rectangles for any highlight;" +
                " the page is right but nothing will be marked"
            );
          }
          const shown = page === null ? 0 : page;
          return { page: shown, rects: rects.filter((rect) => rect && rect.pageIndex === shown) };
        }

        // The highlight's own `offset`/`length` are ABSOLUTE within the paragraph
        // (projection.ex adds the ref's offset before emitting them) and are
        // narrower than the ref: a whole-paragraph rewrite reports only the range
        // that actually differs. Prefer them; the ref is the fallback.
        function previewHighlightRange(highlight, ref) {
          const source = highlight && typeof highlight === "object" ? highlight : {};
          const offset = pickInt(source, ["offset"]);
          const length = pickInt(source, ["length"]);
          return {
            offset: offset === null ? ref.offset : offset,
            length: length === null
              ? (Number.isSafeInteger(ref.length) ? ref.length : undefined)
              : length
          };
        }

        async function previewRefForHighlight(renderer, highlight) {
          const ref = parseHostRef(highlight && highlight.ref);
          if (ref) return ref;
          const query = String((highlight && (highlight.text || highlight.replacement)) || "");
          if (!query) return null;
          const found = await renderer.transport.call("docFind", {
            query,
            caseSensitive: true,
            includeCells: true,
            limit: 1
          });
          const hit = Array.isArray(found && found.hits) ? found.hits[0] : null;
          return hit ? hitToRef(hit) : null;
        }

        async function previewPageForRef(renderer, ref) {
          // A cell ref answers `kind: "cell"`, which carries no page; the table's
          // anchor paragraph does.
          const paragraph = ref.cell ? ref.cell.parentPara : ref.paragraph;
          const info = await renderer.transport.call("docGet", {
            ref: { section: ref.section, paragraph, offset: 0 }
          });
          return info && Number.isSafeInteger(info.page) ? info.page : null;
        }

        // The edit highlight itself. Drawn INTO the page SVG rather than as a
        // sibling overlay element: the rects and the viewBox are the same page-px
        // space, so one string splice survives every card size without a resize
        // listener, and the <img> stays a single decoded image.
        //
        // Amber fill + amber stroke is the shared "an agent changed this" language
        // — the same colours the office canvas paints (`paintAdornmentsOnPage`)
        // and the deleted HWP canvas painted before it.
        function withEditHighlights(svg, rects) {
          const text = String(svg == null ? "" : svg);
          if (!Array.isArray(rects) || rects.length === 0) return text;
          const close = text.lastIndexOf("</svg>");
          if (close < 0) return text;
          const shapes = rects
            .map((rect) => {
              const x = Number(rect.x || 0);
              const y = Number(rect.y || 0);
              const width = Math.max(1, Number(rect.width || 0));
              const height = Math.max(1, Number(rect.height || 0));
              // A hair of vertical padding: an engine rect is the glyph box, and
              // a highlighter that stops exactly at the cap height reads as a
              // rendering seam rather than as a mark.
              return (
                `<rect x="${(x - 1).toFixed(1)}" y="${(y - 1).toFixed(1)}"` +
                ` width="${(width + 2).toFixed(1)}" height="${(height + 2).toFixed(1)}"` +
                ` fill="rgba(245,158,11,0.26)" stroke="rgba(217,119,6,0.95)" stroke-width="1.5"` +
                ` rx="1.5" ry="1.5" />`
              );
            })
            .join("");
          return `${text.slice(0, close)}<g data-role="ecrits-edit-highlights">${shapes}</g>${text.slice(close)}`;
        }

        // One document at a time: loadFile replaces the renderer's whole document,
        // so two cards resolving in parallel would race for the same engine.
        function queuePreviewRender(task) {
          previewBusy += 1;
          const run = () => task();
          const next = previewChain.then(run, run);
          previewChain = next.then(() => {}, () => {});
          return next.finally(() => {
            previewBusy = Math.max(0, previewBusy - 1);
            schedulePreviewTeardown();
          });
        }

        // A card is keyed by its bytes AND by what it is pointing at: two cards can
        // share a committed snapshot and highlight different ranges of it, and the
        // painted image now carries the highlight, so the page number alone is no
        // longer a sufficient cache key.
        function previewHighlightKey(highlights) {
          if (!Array.isArray(highlights) || highlights.length === 0) return "-";
          try {
            return JSON.stringify(
              highlights.slice(0, PREVIEW_HIGHLIGHT_PROBES).map((raw) => {
                const highlight = raw && typeof raw === "object" ? raw : {};
                return [
                  highlight.ref === undefined ? null : highlight.ref,
                  pickInt(highlight, ["offset"]),
                  pickInt(highlight, ["length"]),
                  typeof highlight.text === "string" ? highlight.text : null
                ];
              })
            );
          } catch (_) {
            return "-";
          }
        }

        async function previewPageImage(url, fileName, highlights) {
          const renderer = previewRenderer;
          if (!renderer) throw new Error("the shared preview renderer was released");
          if (renderer.loadedUrl !== url) {
            const response = await fetch(url, { credentials: "same-origin" });
            if (!response.ok) throw new Error(`preview fetch failed: ${response.status}`);
            const buffer = await response.arrayBuffer();
            await renderer.transport.call("ready");
            // Cleared BEFORE the call: a loadFile that throws leaves the engine
            // holding whichever document it managed to get to.
            renderer.loadedUrl = null;
            await renderer.transport.call(
              "loadFile",
              { data: new Uint8Array(buffer), fileName, skipUnsavedGuard: true, suppressDialogs: true },
              [buffer]
            );
            renderer.loadedUrl = url;
          }
          const geometry = await resolvePreviewGeometry(renderer, highlights);
          const page = geometry.page;
          const cacheKey = previewCacheKey(url, highlights);
          previewPages.set(url, { page, cacheKey });
          const key = `${cacheKey}#${page}`;
          const cached = previewImages.get(key);
          if (cached) return { objectUrl: cached, page, highlighted: geometry.rects.length };
          const svg = await renderer.transport.call("getPageSvg", { page });
          const painted = withEditHighlights(svg, geometry.rects);
          const objectUrl = URL.createObjectURL(new Blob([painted], { type: "image/svg+xml" }));
          rememberPreviewImage(key, objectUrl);
          return { objectUrl, page, highlighted: geometry.rects.length };
        }

        function previewCacheKey(url, highlights) {
          return `${url}|${previewHighlightKey(highlights)}`;
        }

        function cachedPreviewImage(url, highlights) {
          const entry = previewPages.get(url);
          if (!entry) return null;
          const cacheKey = previewCacheKey(url, highlights);
          if (entry.cacheKey !== cacheKey) return null;
          const objectUrl = previewImages.get(`${cacheKey}#${entry.page}`);
          return objectUrl ? { objectUrl, page: entry.page } : null;
        }

        function createPreviewCard(hook) {
          const host = hook.el.querySelector("[data-role='rhwp-studio-preview']");
          const image = host && host.querySelector("[data-role='rhwp-studio-preview-page']");
          const status = host && host.querySelector("[data-role='rhwp-studio-preview-status']");
          const card = { destroyed: false, paintedUrl: null, holding: false };

          // The engine is booted on the first card that actually needs a render.
          // A card whose page is already cached — or that has no bytes to render
          // at all — never starts one.
          function holdRenderer() {
            if (card.holding) return;
            card.holding = true;
            acquirePreviewRenderer();
          }

          function setStatus(text) {
            if (!status) return;
            status.textContent = text || "";
            status.hidden = !text;
          }

          function paint(key, rendered) {
            if (!image) return;
            image.src = rendered.objectUrl;
            image.hidden = false;
            image.setAttribute("data-preview-page", String(rendered.page));
            if (rendered.highlighted != null) {
              image.setAttribute("data-preview-highlights", String(rendered.highlighted));
            }
            card.paintedUrl = key;
            setStatus("");
          }

          function clearImage() {
            if (!image) return;
            image.removeAttribute("src");
            image.hidden = true;
            card.paintedUrl = null;
          }

          function render() {
            if (card.destroyed || !host) return;
            const state = readCanvasState(hook.el);
            const url = state.bytesUrl;
            if (!url) {
              // A pinned snapshot that failed to take: the card header already
              // names the edit, so say why the page is missing instead of
              // pretending to render one.
              clearImage();
              setStatus("Preview bytes unavailable");
              return;
            }
            let highlights = [];
            try {
              const parsed = JSON.parse(state.previewHighlights || "[]");
              if (Array.isArray(parsed)) highlights = parsed;
            } catch (_) {
              // The server always encodes a list; a malformed one just means
              // "render the first page".
            }
            const key = previewCacheKey(url, highlights);
            if (key === card.paintedUrl) return;
            const cached = cachedPreviewImage(url, highlights);
            if (cached) {
              paint(key, cached);
              return;
            }
            holdRenderer();
            setStatus("Rendering preview…");
            const path = state.documentPath || "";
            const fileName =
              path.split("/").filter(Boolean).pop() ||
              `document.${(state.localDocumentFormat || "hwp").toLowerCase()}`;
            queuePreviewRender(async () => {
              // The card may have been replaced (a newer snapshot) or destroyed
              // while this render waited its turn in the queue.
              if (card.destroyed) return;
              if (readCanvasState(hook.el).bytesUrl !== url) return;
              try {
                const rendered = await previewPageImage(url, fileName, highlights);
                if (card.destroyed || readCanvasState(hook.el).bytesUrl !== url) return;
                paint(key, rendered);
              } catch (error) {
                if (card.destroyed) return;
                console.error("[rhwp-studio] preview render failed", error);
                setStatus(describeError(error));
              }
            });
          }

          card.render = render;
          card.destroy = () => {
            card.destroyed = true;
            if (!card.holding) return;
            card.holding = false;
            releasePreviewRenderer();
          };
          return card;
        }

        // One load, one viewer-state claim. Every path that loads a document goes
        // through here so the Session viewer registration can never drift from
        // what the embed actually holds.
        function loadAndClaim(session, payload) {
          return session
            .loadDocument(payload)
            .then((loaded) => {
              session.notifyViewerState(loaded !== false);
              return loaded;
            })
            .catch((error) => {
              session.notifyViewerState(false);
              throw error;
            });
        }

        const RhwpStudioEmbed = {
          mounted() {
            // A mirror boots no engine of its own, answers no command and arms
            // no picker: it paints a page rendered by the shared renderer above.
            if (readCanvasState(this.el).editorMirror === true) {
              const card = createPreviewCard(this);
              previewCards.set(this, card);
              card.render();
              return;
            }

            const session = createSession(this);
            sessions.set(this, session);

            this.handleEvent("document.hwp.load_command", (payload) => {
              if (!session.matchesDocument(payload)) return;
              loadAndClaim(session, payload).catch((error) => {
                console.error("[rhwp-studio] load failed", error);
              });
            });
            this.handleEvent("document.engine.operation.command", (payload) => {
              if (!session.matchesDocument(payload)) return;
              session.handleEngineCommand(payload);
            });
            this.handleEvent("document.save.command", (payload) => {
              if (!session.matchesDocument(payload)) return;
              session.handleSaveCommand(payload);
            });

            session.installPicker();

            const bytesUrl = session.canvasState().bytesUrl;
            if (bytesUrl) {
              loadAndClaim(session, {
                url: bytesUrl,
                document_id: session.canvasState().documentId
              }).catch((error) => console.error("[rhwp-studio] initial load failed", error));
            }
          },
          updated() {
            const card = previewCards.get(this);
            if (card) {
              card.render();
              return;
            }
            const session = sessions.get(this);
            if (!session) return;
            const nextState = session.canvasState();
            const bytesUrl = nextState.bytesUrl;
            if (!bytesUrl || bytesUrl === session.state.loadedUrl) return;
            loadAndClaim(session, { url: bytesUrl, document_id: nextState.documentId })
              .catch((error) => console.error("[rhwp-studio] reload failed", error));
          },
          destroyed() {
            const card = previewCards.get(this);
            if (card) {
              previewCards.delete(this);
              card.destroy();
              return;
            }
            const session = sessions.get(this);
            if (!session) return;
            sessions.delete(this);
            // This embed no longer holds the model, so relinquish the Session
            // viewer claim before tearing the transport down. A stale claim would
            // route the agent's next read to a dead engine.
            session.notifyViewerState(false);
            session.destroy();
          }
        };

        export default RhwpStudioEmbed;
      </script>
    </div>
    """
  end
end
