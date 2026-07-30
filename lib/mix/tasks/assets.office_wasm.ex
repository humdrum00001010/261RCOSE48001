defmodule Mix.Tasks.Assets.OfficeWasm do

  import Ecrits.Guards
  @shortdoc "Copies a built LibreOffice WASM bundle into priv/static/office-wasm"

  @moduledoc """
  Office engine delivery for Layer 4 of the DocLang engine migration.

  Replaces the retired no-op alias of the same name. The office WASM bundle used
  to ride the `:libreofficex` dep's `priv/wasm`; that dep was deleted 2026-07-26,
  so the bundle now comes from a LibreOffice-for-emscripten build directory the
  same way `assets.rhwp_studio` takes rhwp-studio's `dist/` — built in a sibling
  checkout, only the built artifacts shipped here.

      OFFICE_WASM_DIST=<core-wasm-build>/instdir/program mix assets.office_wasm

  ## Which build

  The **headless** (`--disable-gui`) build, i.e. the one whose `main()` reaches
  the `libreofficekit_hook_2` bootstrap and exports the `LokEditBindings` embind
  API (`loadFromBytes`, `paintTile`, `elements`, `uno_apply`, `uno_set`,
  `hitRef`, `resolveRef`, `lok_is_ready`). That is the API
  `EcritsWeb.Live.Studio.Components.Canvas.OfficeWasm` drives, end to end.

  A Qt6 GUI build (`--enable-qt6`) is NOT interchangeable here even though it
  links the same static library: its `main()` goes to `soffice_main()`, so
  `lok_start_worker()`/`lok_set_fully_ready()` never run and the lazy
  `ensure_office()` would re-bootstrap UNO, force `SAL_USE_VCLPLUGIN=svp` and
  start a *second* `soffice_main()`. See the office go/no-go section of
  `docs/plans/2026-07-26-doclang-engine-migration.md`.

  ## No baked-in default, and no copy unless you ask for one

  A `$HOME/Desktop/...` default would leak a developer path into the build and be
  non-reproducible, so an unset or absent source is a **no-op**: `mix assets.build`
  still succeeds on a machine without the checkout, the plug 404s and the canvas
  reports a missing engine instead of the request path raising.

  The bundle is ~315 MB (a 197 MB `soffice.wasm` + a 117 MB `soffice.data`), so
  installing it *doubles* that on disk and puts it under `mix phx.digest`'s walk.
  Prefer pointing the server straight at the build output with **no copy at all**:

      export OFFICE_WASM_DIST=<core-wasm-build>/instdir/program

  `config/runtime.exs` lowers that env var into `:office_wasm_dist`, which
  `EcritsWeb.Plugs.CrossOriginIsolationPlug.office_dir/0` prefers over the
  installed copy. Run this task when you need a self-contained `priv/static`.

  Only the four files the plug allowlists are copied — the source is an `instdir/
  program` tree with hundreds of unrelated files. The swap is copy-to-tmp then
  rename, because a live tab reloading mid-copy would otherwise fetch a truncated
  wasm.
  """

  use Mix.Task

  @dest Path.join(~w(priv static office-wasm))

  # Exactly `CrossOriginIsolationPlug`'s `@office_files`: the matched glue/engine/
  # data/metadata set. Serving a mixed-vintage subset breaks WASM validation
  # before the office runtime can start, so the installer and the server
  # allowlist must name the same four files.
  @files ~w(soffice.js soffice.wasm soffice.data soffice.data.js.metadata)

  # Retired scratch output from the dep-era pipeline. Purged unconditionally so a
  # stale `/assets/office/*` copy can never shadow the real bundle.
  @retired ~w(priv/static/assets/office assets/vendor/office)

  @impl Mix.Task
  def run(argv) do
    Enum.each(@retired, &File.rm_rf!/1)

    src = source_dir(argv)

    cond do
      is_nil(src) ->
        Mix.shell().info(
          "[assets.office_wasm] skipped: set OFFICE_WASM_DIST to a built LibreOffice wasm dir"
        )

      missing = Enum.find(@files, &(not File.regular?(Path.join(src, &1)))) ->
        Mix.shell().info("[assets.office_wasm] skipped: #{src} has no #{missing}")

      true ->
        install(src)
    end
  end

  defp source_dir([dir | _]) when is_present(dir), do: Path.expand(dir)

  defp source_dir(_argv) do
    case System.get_env("OFFICE_WASM_DIST") do
      dir when is_present(dir) -> Path.expand(dir)
      _unset -> nil
    end
  end

  defp install(src) do
    tmp = @dest <> ".tmp"
    prev = @dest <> ".prev"

    File.rm_rf!(tmp)
    File.rm_rf!(prev)
    File.mkdir_p!(tmp)

    for name <- @files do
      File.cp!(Path.join(src, name), Path.join(tmp, name))
    end

    if File.dir?(@dest), do: File.rename!(@dest, prev)
    File.rename!(tmp, @dest)
    File.rm_rf!(prev)

    Mix.shell().info("[assets.office_wasm] #{src} -> #{@dest} (#{byte_summary(@dest)})")
  end

  defp byte_summary(dir) do
    bytes =
      Enum.reduce(@files, 0, fn name, acc ->
        case File.stat(Path.join(dir, name)) do
          {:ok, %File.Stat{type: :regular, size: size}} -> acc + size
          _other -> acc
        end
      end)

    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end
end
