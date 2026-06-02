defmodule Ecrits.Export.PDF do
  @moduledoc """
  PDF renderer.

  Pipeline: project → HTML (via `Ecrits.Export.HTML.render/2`) → write
  a temp file → invoke headless Chromium-for-Testing
  (`--print-to-pdf=…`) → read the PDF bytes back into memory.

  The Chromium binary path is resolved from (in order):

    1. The `:chromium_path` option in `opts`.
    2. `Application.get_env(:ecrits, :chromium_path)` (set in
       `config/runtime.exs` from `CHROMIUM_PATH`).
    3. `System.find_executable("chromium")` / `"google-chrome"` /
       `"chromium-browser"`.

  ## Determinism

  Chromium's PDF writer embeds a fixed `/CreationDate` unless we pass
  one, so output is not byte-deterministic across runs by default.
  Callers that need byte-equal output (e.g. snapshot tests) must use
  `Ecrits.Export.HTML.render/2` for the deterministic projection
  representation; the PDF wrapper is best-effort. Within a single
  Chromium build + the same HTML input, contents are stable enough for
  smoke checks (magic header + page count).
  """

  alias Ecrits.Export
  alias Ecrits.Runtime.State

  @spec render(State.t() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(state_or_projection, opts \\ [])

  def render(%State{} = state, opts), do: render_with_html(state, opts)
  def render(projection, opts) when is_map(projection), do: render_with_html(projection, opts)

  defp render_with_html(input, opts) do
    with {:ok, html} <- Export.HTML.render(input, opts),
         {:ok, chromium} <- find_chromium(opts) do
      run_chromium(chromium, html)
    end
  end

  # --------------------------------------------------------------------
  # internals
  # --------------------------------------------------------------------

  defp find_chromium(opts) do
    candidate =
      Keyword.get(opts, :chromium_path) ||
        Application.get_env(:ecrits, :chromium_path) ||
        System.find_executable("chromium") ||
        System.find_executable("google-chrome") ||
        System.find_executable("chromium-browser")

    cond do
      is_nil(candidate) ->
        {:error, :chromium_not_found}

      not is_binary(candidate) ->
        {:error, {:chromium_invalid, candidate}}

      true ->
        # If the configured path doesn't exist on this host but is on
        # $PATH under its bare name, fall back to PATH lookup.
        if File.exists?(candidate) do
          {:ok, candidate}
        else
          case System.find_executable(Path.basename(candidate)) do
            nil -> {:error, {:chromium_missing, candidate}}
            resolved -> {:ok, resolved}
          end
        end
    end
  end

  defp run_chromium(chromium, html) do
    tmp_dir = System.tmp_dir!()
    unique = System.unique_integer([:positive, :monotonic])
    html_path = Path.join(tmp_dir, "contract-export-#{unique}.html")
    pdf_path = Path.join(tmp_dir, "contract-export-#{unique}.pdf")

    try do
      :ok = File.write!(html_path, html)

      args = [
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--no-pdf-header-footer",
        "--print-to-pdf=#{pdf_path}",
        "file://#{html_path}"
      ]

      case System.cmd(chromium, args, stderr_to_stdout: true) do
        {_output, 0} ->
          read_pdf(pdf_path)

        {output, code} ->
          {:error, {:chromium_exit, code, String.slice(output, 0, 2_000)}}
      end
    rescue
      e -> {:error, {:pdf_render_failed, Exception.message(e)}}
    after
      _ = File.rm(html_path)
      _ = File.rm(pdf_path)
    end
  end

  defp read_pdf(path) do
    case File.read(path) do
      {:ok, <<"%PDF-", _::binary>> = bin} -> {:ok, bin}
      {:ok, bin} -> {:error, {:pdf_bad_magic, byte_size(bin)}}
      {:error, reason} -> {:error, {:pdf_read_failed, reason}}
    end
  end
end
