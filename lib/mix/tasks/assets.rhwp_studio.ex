defmodule Mix.Tasks.Assets.RhwpStudio do

  import Ecrits.Guards
  @shortdoc "Copies a built rhwp-studio bundle into priv/static/rhwp-studio"

  @moduledoc """
  HWP engine delivery for Layer 4 of the DocLang engine migration.

  rhwp-studio is a Vite/TypeScript app that lives in the **rhwp_core** checkout.
  This repo carries no Node toolchain (all Node/npm was removed 2026-07-19), so
  the bundle is built there and only the built `dist/` is shipped here — the same
  split the retired `:ehwp` / `:libreofficex` wasm bundles used, except the source
  is a sibling checkout instead of a hex/git dep's `priv/wasm`.

      cd <rhwp_core>/rhwp-studio && npm run build -- --base=/rhwp-studio/
      RHWP_STUDIO_DIST=<rhwp_core>/rhwp-studio/dist mix assets.rhwp_studio

  `--base=/rhwp-studio/` matters: Vite defaults to `/`, which would make the
  bundle request `/assets/index-*.js` and collide with this app's own
  `/assets` tree.

  No default source path is baked in on purpose. A `$HOME/Desktop/...` default
  would leak a user path into the build and be non-reproducible; an unset or
  absent source is a **no-op** so `mix assets.build` still succeeds on a machine
  without the checkout (the plug then 404s and the host reports a missing bundle
  instead of the request path raising).

  `samples/` is excluded — 7.5 MB of demo documents the embedded host never
  opens. The swap is copy-to-tmp then rename, because a live tab reloading
  mid-copy would otherwise fetch a truncated wasm.
  """

  use Mix.Task

  @dest Path.join(~w(priv static rhwp-studio))
  @excluded ~w(samples)

  @impl Mix.Task
  def run(argv) do
    src = source_dir(argv)

    cond do
      is_nil(src) ->
        Mix.shell().info(
          "[assets.rhwp_studio] skipped: set RHWP_STUDIO_DIST to a built rhwp-studio dist"
        )

      not File.regular?(Path.join(src, "index.html")) ->
        Mix.shell().info(
          "[assets.rhwp_studio] skipped: #{src} has no index.html (build rhwp-studio first)"
        )

      true ->
        install(src)
    end
  end

  defp source_dir([dir | _]) when is_present(dir), do: Path.expand(dir)

  defp source_dir(_argv) do
    case System.get_env("RHWP_STUDIO_DIST") do
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

    for entry <- File.ls!(src), entry not in @excluded do
      File.cp_r!(Path.join(src, entry), Path.join(tmp, entry))
    end

    if File.dir?(@dest), do: File.rename!(@dest, prev)
    File.rename!(tmp, @dest)
    File.rm_rf!(prev)

    Mix.shell().info("[assets.rhwp_studio] #{src} -> #{@dest} (#{byte_summary(@dest)})")
  end

  defp byte_summary(dir) do
    bytes =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reduce(0, fn path, acc ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :regular, size: size}} -> acc + size
          _other -> acc
        end
      end)

    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end
end
