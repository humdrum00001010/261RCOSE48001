defmodule EcritsWeb.Plugs.CrossOriginIsolationPlug do
  @moduledoc """
  Serves the browser WASM engine bundles and opts the LibreOffice->WASM client
  editor into cross-origin isolation.

  ## Cross-origin isolation

  The office WASM build (`soffice.wasm`) is an Emscripten
  PThreads build: it allocates a *shared* `WebAssembly.Memory` (`shared: true`),
  which requires `SharedArrayBuffer`, which the browser only exposes when the
  page is **cross-origin isolated** (`crossOriginIsolated === true`). That in turn
  requires the document response to carry:

      Cross-Origin-Opener-Policy:   same-origin
      Cross-Origin-Embedder-Policy: require-corp

  We set these ONLY on the local workspace page, the `/assets/office/*` WASM
  artifacts, and the dev-only `/phoenix/live_reload/frame` iframe (which must
  itself carry COEP to remain embeddable in the isolated workspace page — see
  `isolate?/1`), not the whole app, to keep the blast radius small — COOP/COEP
  can block cross-origin embeds elsewhere. `require-corp` has broader browser
  support than `credentialless`, and the local workspace uses same-origin assets
  for the chrome needed by the office editor.

  We also stamp `Cross-Origin-Resource-Policy: same-origin` so the same-origin
  WASM/data files remain loadable from the isolated page.

  ## Asset delivery

  `/assets/office/*` serves the four-file LibreOffice WASM set (glue, engine,
  FS image, metadata) from `office_dir/0` — either a build directory named by
  `OFFICE_WASM_DIST` or the copy `mix assets.office_wasm` installs into
  `priv/static/office-wasm`. It moved off the `:libreofficex` dep's `priv/wasm`
  when that dep was deleted (2026-07-26).

  Always serve the canonical identity file. Pre-compressed `.br` siblings are
  local/generated scratch output and can become stale or corrupt relative to the
  raw artifact; serving one with `content-encoding: br` breaks browser WASM
  validation before the Office runtime can start.

  The `/assets/rhwp/*` prefix is **gone** with the legacy `Canvas.HwpPages` hook
  that fetched it: rhwp-studio ships its own `rhwp_bg.wasm` inside the bundle
  below, so there is no second HWP wasm to serve.

  `/rhwp-studio/*` serves the rhwp-studio bundle (the HWP engine, hosted in an
  iframe over its embed RPC — see
  `EcritsWeb.Live.Studio.Components.Canvas.RhwpStudio`). Unlike the two wasm
  prefixes above it is a whole build tree, not a fixed file list, so the
  allowlist is replaced by `Path.safe_relative/2` confinement under the bundle
  root. It is served here rather than by `Plug.Static` for two reasons: the
  bundle root is configurable (`:rhwp_studio_dist`) so a dev machine can point
  straight at the rhwp_core build output, and `Plug.Static`'s `:only` list is
  compiled with `raise_on_missing_only`, which would turn "bundle not installed
  yet" into a boot failure instead of a 404.

  The studio iframe is embedded by `/workspace`, which is COEP `require-corp`;
  a `require-corp` document may only frame responses that themselves declare
  COEP, so `/rhwp-studio/*` is isolated too (same reason the dev live-reload
  frame is).
  """

  import Ecrits.Guards

  @behaviour Plug

  import Plug.Conn

  @office_prefix "/assets/office/"
  @studio_prefix "/rhwp-studio/"

  @office_files ~w(soffice.js soffice.wasm soffice.data soffice.data.js.metadata)

  @doc """
  Filesystem root the `/assets/office/` WASM set is served from.

  Overridable with `config :ecrits, :office_wasm_dist, "/path/to/instdir/program"`
  (lowered from `OFFICE_WASM_DIST` in `config/runtime.exs`) so a dev machine can
  serve a LibreOffice-for-emscripten build directory with no copy at all — the
  bundle is ~315 MB and duplicating it is the whole cost of installing it.
  Otherwise the copy installed by `mix assets.office_wasm`.

  Must be the **headless** (`--disable-gui`) build: it is the one whose `main()`
  bootstraps LibreOfficeKit and whose `LokEditBindings` embind API
  (`loadFromBytes`/`paintTile`/`elements`/`uno_apply`) the office canvas drives.
  A Qt6 GUI build links the same symbols but never runs `lok_start_worker()` or
  `lok_set_fully_ready()`, so the canvas would hang on its readiness gate.
  """
  @spec office_dir() :: String.t()
  def office_dir do
    case Application.get_env(:ecrits, :office_wasm_dist) do
      dir when is_present(dir) -> dir
      _default -> priv_static_dir("office-wasm")
    end
  end

  @doc """
  Filesystem root the `/rhwp-studio/` bundle is served from.

  Overridable with `config :ecrits, :rhwp_studio_dist, "/path/to/dist"` so a dev
  machine can serve the rhwp_core build output directly; otherwise the copy
  installed by `mix assets.rhwp_studio`.
  """
  @spec studio_dir() :: String.t()
  def studio_dir do
    case Application.get_env(:ecrits, :rhwp_studio_dist) do
      dir when is_present(dir) -> dir
      _default -> priv_static_dir("rhwp-studio")
    end
  end

  defp priv_static_dir(name) do
    case :code.priv_dir(:ecrits) do
      priv when is_list(priv) -> Path.join([List.to_string(priv), "static", name])
      _not_loaded -> Path.join(["priv", "static", name])
    end
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> maybe_isolate()
    |> maybe_serve_wasm_asset()
  end

  defp maybe_isolate(conn) do
    if isolate?(conn) do
      conn
      |> put_resp_header("cross-origin-opener-policy", "same-origin")
      |> put_resp_header("cross-origin-embedder-policy", "require-corp")
      |> put_resp_header("cross-origin-resource-policy", "same-origin")
    else
      conn
    end
  end

  # Serve dependency-owned WASM assets directly.
  defp maybe_serve_wasm_asset(%Plug.Conn{method: method, request_path: path} = conn)
       when method in ["GET", "HEAD"] do
    with {:ok, raw_path, content_type} <- asset_file(path) do
      send_asset(conn, raw_path, content_type)
    else
      :error -> conn
    end
  end

  defp maybe_serve_wasm_asset(conn), do: conn

  defp send_asset(conn, path, content_type) do
    conn =
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", "no-cache")

    case conn.method do
      "HEAD" ->
        conn
        |> send_resp(200, "")
        |> halt()

      _ ->
        conn
        |> send_file(200, path)
        |> halt()
    end
  end

  defp asset_file(path) do
    cond do
      String.starts_with?(path, @office_prefix) ->
        path
        |> String.trim_leading(@office_prefix)
        |> asset_file(office_dir(), @office_files)

      path == String.trim_trailing(@studio_prefix, "/") ->
        studio_file("index.html")

      String.starts_with?(path, @studio_prefix) ->
        path
        |> String.trim_leading(@studio_prefix)
        |> studio_file()

      true ->
        :error
    end
  end

  # A whole build tree, so confine by path instead of by allowlist: reject any
  # relative path that escapes the bundle root (`..`, absolute, symlinked-out).
  defp studio_file(""), do: studio_file("index.html")

  defp studio_file(rel) do
    dir = studio_dir()

    with {:ok, safe} <- Path.safe_relative(URI.decode(rel), dir),
         raw_path = Path.join(dir, safe),
         true <- File.regular?(raw_path) do
      {:ok, raw_path, content_type_for(Path.extname(safe))}
    else
      _ -> :error
    end
  end

  defp asset_file(rel, dir, allowed_files) do
    with true <- rel in allowed_files,
         raw_path = Path.join(dir, rel),
         true <- File.regular?(raw_path) do
      {:ok, raw_path, content_type_for(Path.extname(rel))}
    else
      _ -> :error
    end
  end

  defp content_type_for(".wasm"), do: "application/wasm"
  defp content_type_for(".js"), do: "text/javascript; charset=utf-8"
  defp content_type_for(".mjs"), do: "text/javascript; charset=utf-8"
  defp content_type_for(".data"), do: "application/octet-stream"
  defp content_type_for(".metadata"), do: "application/json; charset=utf-8"
  defp content_type_for(".html"), do: "text/html; charset=utf-8"
  defp content_type_for(".css"), do: "text/css; charset=utf-8"
  defp content_type_for(".json"), do: "application/json; charset=utf-8"
  defp content_type_for(".webmanifest"), do: "application/manifest+json; charset=utf-8"
  defp content_type_for(".svg"), do: "image/svg+xml"
  defp content_type_for(".png"), do: "image/png"
  defp content_type_for(".jpg"), do: "image/jpeg"
  defp content_type_for(".jpeg"), do: "image/jpeg"
  defp content_type_for(".ico"), do: "image/x-icon"
  defp content_type_for(".woff2"), do: "font/woff2"
  defp content_type_for(".woff"), do: "font/woff"
  defp content_type_for(".ttf"), do: "font/ttf"
  defp content_type_for(".otf"), do: "font/otf"
  defp content_type_for(".txt"), do: "text/plain; charset=utf-8"
  defp content_type_for(".md"), do: "text/markdown; charset=utf-8"
  defp content_type_for(_), do: "application/octet-stream"

  # Isolate the workspace HTML page (which hosts the WasmOfficeEditor hook) and
  # the office WASM static artifacts it fetches. Everything else is untouched.
  #
  # The Phoenix live-reload iframe (dev only) must also carry
  # `Cross-Origin-Embedder-Policy: require-corp`: a COEP `require-corp`
  # document (i.e. `/workspace`) may only embed frames whose *responses* also
  # declare COEP — even same-origin ones. Without this, the browser replaces
  # the `/phoenix/live_reload/frame` document with an opaque error page, its
  # websocket never connects, and `/workspace` tabs (notably the Tidewave
  # shell, which always hosts `/workspace`) silently stop live-reloading and
  # keep running stale JS bundles after asset rebuilds. This plug runs before
  # `Phoenix.LiveReloader` in the endpoint, so headers set here are included
  # when the frame response is sent. In prod the path 404s and the extra
  # headers are inert.
  defp isolate?(%Plug.Conn{request_path: path}) do
    path == "/workspace" or
      String.starts_with?(path, @office_prefix) or
      String.starts_with?(path, @studio_prefix) or
      String.starts_with?(path, "/phoenix/live_reload/frame")
  end
end
