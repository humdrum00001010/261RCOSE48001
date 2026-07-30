defmodule EcritsWeb.Live.Studio.Components.Canvas.RhwpStudioTest do
  @moduledoc """
  The HWP arm of Layer 4: rhwp-studio hosted in an iframe over its embed RPC.

  These assertions pin the things the host cannot get wrong — the embed
  protocol v1 handshake shape (version + the mandatory
  `transferable-array-buffer` capability, both hard-checked by studio's
  `isConnectMessage`), the doc-ops-v1 verb wiring, and the fact that the doc-op
  family is gated on the ADVERTISED capability so an older installed bundle
  degrades to a named `embed_rpc_gap:` failure instead of a silent success.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Ecrits.DocumentCanvasState
  alias EcritsWeb.Live.Studio.Components.Canvas.RhwpStudio

  @adapter "lib/ecrits_web/live/studio/components/canvas/rhwp_studio.ex"

  defp render_canvas(attrs \\ %{}) do
    render_component(&RhwpStudio.render/1,
      id: "rhwp-studio-canvas",
      state:
        DocumentCanvasState.new(
          Map.merge(
            %{
              document_id: "sample-hwp",
              document_path: "sample.hwp",
              document_format: "hwp",
              bytes_url: "/workspace/documents/sample.hwp/bytes"
            },
            attrs
          )
        )
    )
  end

  test "renders a same-origin studio iframe as the HWP canvas" do
    html = render_canvas() |> LazyHTML.from_fragment()

    host = html |> LazyHTML.query(~s([data-component="canvas-rhwp-studio"])) |> Enum.at(0)
    assert host
    assert LazyHTML.attribute(host, "data-renderer") == ["rhwp-studio"]

    assert LazyHTML.attribute(host, "phx-hook") ==
             ["EcritsWeb.Live.Studio.Components.Canvas.RhwpStudio.RhwpStudioEmbed"]

    assert LazyHTML.attribute(host, "data-canvas-state") != []

    frame = html |> LazyHTML.query(~s([data-role="rhwp-studio-frame"])) |> Enum.at(0)
    assert frame
    assert LazyHTML.attribute(frame, "src") == ["/rhwp-studio/index.html"]
    # The engine owns its own DOM; LiveView must never patch inside it.
    assert LazyHTML.attribute(frame, "phx-update") == ["ignore"]
  end

  test "mirror previews are inert" do
    html = render_canvas(%{mirror?: true}) |> LazyHTML.from_fragment()
    host = html |> LazyHTML.query(~s([data-component="canvas-rhwp-studio"])) |> Enum.at(0)

    assert LazyHTML.attribute(host, "aria-label") == ["Document preview"]
    assert host |> LazyHTML.attribute("class") |> List.first() =~ "pointer-events-none"
  end

  # The regression this file exists to prevent: a chat-rail preview card that
  # renders NOTHING. A mirror boots no engine of its own — it paints a page image
  # produced by the one shared renderer — so it must ship the <img> the hook
  # paints into, and must NOT ship a studio iframe.
  test "a mirror renders a page image, not an iframe" do
    html = render_canvas(%{mirror?: true}) |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query(~s([data-role="rhwp-studio-frame"])) |> Enum.to_list() == []

    preview = html |> LazyHTML.query(~s([data-role="rhwp-studio-preview"])) |> Enum.at(0)
    assert preview
    # The hook owns this subtree's contents; a LiveView patch must not wipe the
    # painted image.
    assert LazyHTML.attribute(preview, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(preview, "id") == ["rhwp-studio-canvas-preview"]

    image = html |> LazyHTML.query(~s([data-role="rhwp-studio-preview-page"])) |> Enum.at(0)
    assert image
    assert LazyHTML.attribute(image, "hidden") != []

    status = html |> LazyHTML.query(~s([data-role="rhwp-studio-preview-status"])) |> Enum.at(0)
    assert status
  end

  test "the editor arm still owns a studio iframe" do
    html = render_canvas() |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query(~s([data-role="rhwp-studio-frame"])) |> Enum.count() == 1
    assert html |> LazyHTML.query(~s([data-role="rhwp-studio-preview"])) |> Enum.to_list() == []
  end

  describe "shared preview renderer" do
    setup do
      {:ok, source: File.read!(@adapter)}
    end

    # N cards must not mean N engines: one renderer for the whole page, held by
    # reference count and released after an idle period, with the rendered pages
    # cached so a re-mount repaints without booting anything.
    test "every mirror shares one engine", %{source: source} do
      assert source =~ "let previewRenderer = null;"
      assert source =~ "function acquirePreviewRenderer()"
      assert source =~ "function releasePreviewRenderer()"
      assert source =~ "if (previewRenderer) return previewRenderer;"
      assert source =~ "function schedulePreviewTeardown()"
      assert source =~ "const previewImages = new Map();"
      # One document at a time — loadFile replaces the renderer's whole document.
      assert source =~ "function queuePreviewRender(task)"
    end

    # The 35x latency finding: a browser throttles timers in a frame it does not
    # render, and studio awaits a paint between its load steps.
    test "the renderer iframe stays inside the viewport", %{source: source} do
      assert source =~
               "position:fixed;left:0;bottom:0;width:2px;height:2px;border:0;opacity:0;pointer-events:none;z-index:-1"

      refute source =~ "left:-20000px"
      refute source =~ ~s(frame.style.display = "none")
    end

    # A page image, not a live editor: an <img> executes no script and inherits
    # none of the host's CSS.
    test "the page rides an image blob", %{source: source} do
      assert source =~ ~S|renderer.transport.call("getPageSvg", { page })|
      assert source =~ ~S|URL.createObjectURL(new Blob([painted], { type: "image/svg+xml" }))|
      assert source =~ "image.src = rendered.objectUrl;"
    end

    # The card shows the page the EDIT landed on, resolved from the highlights
    # the server already ships, and falls back to the first page rather than to
    # nothing.
    test "the previewed page follows the edit", %{source: source} do
      assert source =~ "async function resolvePreviewGeometry(renderer, highlights)"
      assert source =~ ~S|renderer.transport.call("docGet"|
      assert source =~ ~S|renderer.transport.call("docFind"|
      assert source =~ "if (!renderer.transport.hasCapability(DOC_OPS_CAPABILITY)) return empty;"
    end

    # THE REGRESSION THIS BLOCK EXISTS FOR. The server has always computed edit
    # highlights (`DocumentCanvasState.preview_highlights` ->
    # `previewHighlights`), the deleted `Canvas.HwpPages` hook painted them, and
    # its replacement dropped them on the floor: highlights were read only to
    # choose WHICH page to show, never to mark anything on it. A card that opens
    # on the right page and marks nothing is the same as no highlight at all.
    test "the edit is marked on the page, not just navigated to", %{source: source} do
      # doc-rects-v1: the engine answers per-line rectangles for the ref.
      assert source =~ ~S|renderer.transport.call("docRects"|
      assert source =~ "function withEditHighlights(svg, rects)"
      # Same page-px space as getPageSvg's viewBox, so the marks are spliced into
      # the SVG string rather than positioned by a resize-sensitive overlay.
      assert source =~ ~S|const painted = withEditHighlights(svg, geometry.rects);|
      assert source =~ ~S|data-role="ecrits-edit-highlights"|
      # The amber the office canvas paints for the same meaning.
      assert source =~ "rgba(245,158,11,0.26)"
      assert source =~ "rgba(217,119,6,0.95)"
      # The highlight's own offset/length are narrower than its ref (a whole
      # paragraph rewrite reports only the range that differs).
      assert source =~ "function previewHighlightRange(highlight, ref)"
      # A repaint must follow the highlight, not just the bytes: two cards can
      # share one committed snapshot and mark different ranges of it.
      assert source =~ "function previewCacheKey(url, highlights)"
      assert source =~ "function previewHighlightKey(highlights)"
    end

    # Per-capability degradation. A bundle with doc-ops-v1 but no doc-rects-v1
    # still opens on the right page and simply draws no marks — it must not fail
    # the card, and it must not call a method that bundle cannot answer.
    test "doc-rects-v1 is its own capability", %{source: source} do
      assert source =~ ~s(const DOC_RECTS_CAPABILITY = "doc-rects-v1";)
      assert source =~ ~s(const DOC_RECTS_METHODS = ["docRects"];)
      assert source =~ "hasCapability(DOC_RECTS_CAPABILITY)"
      assert source =~ "async function previewPageForRef(renderer, ref)"
    end
  end

  describe "embed protocol v1 conformance (rhwp_core/rhwp-studio/src/embed)" do
    setup do
      {:ok, source: File.read!(@adapter)}
    end

    test "handshake matches isConnectMessage's hard checks", %{source: source} do
      assert source =~ "const EMBED_VERSION = 1;"
      # isConnectMessage() rejects any connect whose capabilities omit this one.
      assert source =~ ~s("transferable-array-buffer")
      assert source =~ ~s(type: "rhwp-connect")
      assert source =~ ~s(data.type === "rhwp-connected")
      assert source =~ ~s(data.type === "rhwp-connect-error")
      assert source =~ ~s(type: "rhwp-request")
      assert source =~ ~s(data.type === "rhwp-response")
      # One MessagePort is transferred with the connect; requests ride it.
      assert source =~ "new MessageChannel()"
      assert source =~ "[channel.port2]"
    end

    test "only methods rpc-router.ts routes may be called", %{source: source} do
      # rhwp-studio/src/embed/rpc-router.ts routeEmbedRequest/4 switch arms.
      for method <- ~w(ready loadFile pageCount getRendererDiagnostics getPageSvg
                       exportHwp exportHwpx exportHml getHmlSaveState
                       exportHwpVerify notifySaved) do
        assert source =~ ~s("#{method}"), "EMBED_METHODS must list #{method}"
      end

      # The doc-ops-v1 family, added upstream without a protocol bump.
      for method <- ~w(docRead docFind docEdit docSet docGet
                       docVfsWrite docVfsCommit docVfsFinalize docVfsRollback) do
        assert source =~ ~s("#{method}"), "DOC_OPS_METHODS must list #{method}"
      end

      assert source =~ "embed protocol v1 routes no method"
    end

    # Capability string, not a version bump: studio's connect gate tests
    # `version === 1` exactly, so EMBED_VERSION must stay 1 while the doc-op
    # family is discovered from the handshake reply's capabilities.
    test "doc-ops-v1 is detected as a capability, not a version", %{source: source} do
      assert source =~ ~s(const DOC_OPS_CAPABILITY = "doc-ops-v1";)
      assert source =~ "const EMBED_VERSION = 1;"
      assert source =~ "state.capabilities = Array.isArray(data.capabilities)"
      assert source =~ "function hasCapability(name)"
    end

    # doc-elements-v1 rides the same doc-ops handler object upstream, so a bundle
    # built before it advertises `doc-ops-v1` and would answer
    # `Unknown method: docElements`. It therefore needs its OWN gate, exactly like
    # doc-rects-v1 — and when it is absent the projection must fall back to the
    # paragraph census rather than reporting a complete document it cannot see.
    test "doc-elements-v1 is gated separately and degrades, never overstates",
         %{source: source} do
      assert source =~ ~S|const DOC_ELEMENTS_CAPABILITY = "doc-elements-v1";|
      assert source =~ ~S|const DOC_ELEMENTS_METHODS = ["docElements"];|
      assert source =~ "DOC_ELEMENTS_METHODS.includes(method) && !hasCapability(DOC_ELEMENTS_CAPABILITY)"

      # Preferred when present...
      assert source =~ ~S|if (hasCapability(DOC_ELEMENTS_CAPABILITY)) {|
      assert source =~ ~S|await call("docElements", {})|
      assert source =~ ~S|coverage: "full_ir", complete: true|

      # ...and the body-paragraph census stays as the declared-narrow fallback.
      assert source =~ ~S|coverage: "body_paragraphs"|
      assert source =~ "complete: false"
    end
  end

  # Every mutation/query verb now rides doc-ops-v1 — but the host must never
  # ASSUME it. An installed bundle that predates the upstream change advertises
  # no `doc-ops-v1`, and the verb has to fail naming that instead of timing out
  # on an unknown method or, worse, reporting an edit that never happened.
  test "every doc-ops verb is gated on the advertised capability" do
    source = File.read!(@adapter)

    for verb <- ~w(read find edit set get vfs_write vfs_commit vfs_finalize vfs_rollback) do
      assert source =~ ~r/\n\s+#{verb}:\s+"/,
             "#{verb} must be listed in EMBED_RPC_GAPS with the capability it needs"
    end

    assert source =~ "throw new Error(`embed_rpc_gap:${verb}: ${EMBED_RPC_GAPS[verb]}`)"
    assert source =~ "await requireDocOps(verb);"
    assert source =~ ~S|if (verb === "save") return exportForSave(payload);|

    # The routed verbs, each behind its doc-ops method.
    for {verb, call} <- [
          {"read", "verbRead"},
          {"find", "verbFind"},
          {"edit", "verbEdit"},
          {"set", "verbSet"},
          {"get", "verbGet"},
          {"vfs_write", "verbVfsWrite"}
        ] do
      assert source =~ ~s|if (verb === "#{verb}") return #{call}(payload);|,
             "#{verb} must route to #{call}"
    end
  end

  # The host speaks two ref grammars and doc-ops-v1 speaks one object shape, so
  # the translation is load-bearing: a mis-parsed ref edits the wrong paragraph.
  test "both host ref grammars lower onto the doc-ops ref object" do
    source = File.read!(@adapter)

    assert source =~ "function parseHwpRefString(text)"
    assert source =~ "function parseHostRef(raw)"
    # searchAllText naming, which a docFind hit comes back in.
    assert source =~ ~s("charOffset")
    assert source =~ ~s(raw.cell) <> " || " <> ~s(raw.cellContext)
    # doc-ops-v1's own vocabulary on the way out.
    assert source =~ "function wireRef(ref, offset)"
    assert source =~ "parentPara: ref.cell.parentPara"
  end

  # Verbs with no doc-ops-v1 method must keep naming what is missing rather than
  # being approximated into a wrong answer.
  test "unroutable verbs name the missing engine primitive" do
    source = File.read!(@adapter)

    assert source =~ "WasmBridge.enumerateElements"
    assert source =~ "WasmBridge.mergeParagraphInCell"
    assert source =~ "applyParaFormat/setPictureProperties/setFieldValue"
    assert source =~ "embed_rpc_gap:edit:"
  end

  # A vfs_write's bytes are written straight over the SOURCE FILE, so the
  # container has to be the one already behind that name. The host names the
  # document's format on the request and checks the container doc-ops says it
  # exported before a byte is uploaded — an .hwpx write-back used to be refused
  # outright because upstream always called exportHwp().
  test "vfs_write names the document format and verifies the exported container" do
    source = File.read!(@adapter)

    assert source =~ "const format = documentFormat();"
    assert source =~ "const request = { editId, format };"
    assert source =~ ~S[const exported = (result && result.format) || "hwp";]
    assert source =~ "if (exported !== format)"
    # A bundle predating the format selector omits the echo and only ever
    # exported HWP, so the mismatch is still named as a bundle gap.
    assert source =~ "embed_rpc_gap:vfs_write:"

    # The refusal-by-name stopgap is gone: hwpx sources write back now.
    refute source =~ ~s|documentFormat() === "hwpx"|
    refute source =~ "always exports HWP"
  end

  # rhwp-studio is the ONLY HWP canvas. The `:hwp_canvas` switch and the legacy
  # in-page `Canvas.HwpPages` wasm hook were deleted with the `:ehwp` dep that
  # supplied the hook's engine — there is no second implementation to select and
  # no configuration that brings one back.
  test "the studio iframe is the only HWP canvas" do
    html = render_editor_surface() |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query(~s([data-component="canvas-rhwp-studio"])) |> Enum.count() == 1
    assert html |> LazyHTML.query(~s([data-component="canvas-hwp-pages"])) |> Enum.to_list() == []
    assert html |> LazyHTML.query(~s([data-role="hwp-editor"])) |> Enum.to_list() == []

    refute File.exists?("lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex")

    refute File.read!("lib/ecrits_web/live/studio/components/editor_surface.ex") =~ ":hwp_canvas"
  end

  defp render_editor_surface do
    render_component(&EcritsWeb.Live.Studio.Components.EditorSurface.document/1,
      shell_id: "rhwp-shell",
      toolbar_id: "rhwp-toolbar",
      frame_id: "rhwp-editor-frame",
      state:
        Ecrits.EditorSurfaceState.new(%{
          document: %{id: "07-hwp", format: "hwp", relative_path: "07_공문.hwp"},
          document_path: "07_공문.hwp",
          document_spec: %{key: "hwp", name: "07_공문.hwp", template_hwp_path: "07_공문.hwp"},
          canvas_id: "rhwp-07-hwp",
          open_documents: [],
          active_document_id: "07-hwp",
          dirty_document_ids: MapSet.new(),
          hwp_page_count: 0
        })
    )
  end
end
