defmodule Ecrits.Export.DOCX do
  @moduledoc """
  DOCX renderer.

  Pipeline: project → HTML (via `Ecrits.Export.HTML.render/2`) →
  pipe into `pandoc -f html -t docx -o <tmp>.docx` → read DOCX bytes.

  The pandoc binary path is resolved from (in order):

    1. The `:pandoc_path` option in `opts`.
    2. `Application.get_env(:ecrits, :pandoc_path)`.
    3. `System.find_executable("pandoc")`.

  ## Determinism

  Pandoc embeds a `dcterms:created`/`dcterms:modified` timestamp in
  `docProps/core.xml`. To get byte-identical output we pin
  `SOURCE_DATE_EPOCH=0` in the subprocess env (pandoc honors this since
  2.7.x). The DOCX container is a ZIP; entries are written in stable
  order by pandoc.

  ## Hand-rolled OOXML

  Out of scope by hard constraint — we shell to pandoc. Adding a native
  OOXML writer would duplicate the HWPX engine for a different XML
  dialect and is not justified by the test plan.
  """

  alias Ecrits.Export
  alias Ecrits.Runtime.State

  @spec render(State.t() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(state_or_projection, opts \\ [])

  def render(%State{} = state, opts), do: render_with_html(state, opts)
  def render(projection, opts) when is_map(projection), do: render_with_html(projection, opts)

  defp render_with_html(input, opts) do
    with {:ok, html} <- Export.HTML.render(input, opts),
         {:ok, pandoc} <- find_pandoc(opts) do
      run_pandoc(pandoc, html)
    end
  end

  # --------------------------------------------------------------------
  # internals
  # --------------------------------------------------------------------

  defp find_pandoc(opts) do
    candidate =
      Keyword.get(opts, :pandoc_path) ||
        Application.get_env(:ecrits, :pandoc_path) ||
        System.find_executable("pandoc")

    cond do
      is_nil(candidate) ->
        {:error, :pandoc_not_found}

      not is_binary(candidate) ->
        {:error, {:pandoc_invalid, candidate}}

      true ->
        if File.exists?(candidate) do
          {:ok, candidate}
        else
          case System.find_executable(Path.basename(candidate)) do
            nil -> {:error, {:pandoc_missing, candidate}}
            resolved -> {:ok, resolved}
          end
        end
    end
  end

  defp run_pandoc(pandoc, html) do
    tmp_dir = System.tmp_dir!()
    unique = System.unique_integer([:positive, :monotonic])
    html_path = Path.join(tmp_dir, "contract-export-#{unique}.html")
    docx_path = Path.join(tmp_dir, "contract-export-#{unique}.docx")

    try do
      :ok = File.write!(html_path, html)

      args = [
        "-f",
        "html",
        "-t",
        "docx",
        "-o",
        docx_path,
        html_path
      ]

      env = [{"SOURCE_DATE_EPOCH", "0"}]

      case System.cmd(pandoc, args, stderr_to_stdout: true, env: env) do
        {_output, 0} -> read_docx(docx_path)
        {output, code} -> {:error, {:pandoc_exit, code, String.slice(output, 0, 2_000)}}
      end
    rescue
      e -> {:error, {:docx_render_failed, Exception.message(e)}}
    after
      _ = File.rm(html_path)
      _ = File.rm(docx_path)
    end
  end

  # DOCX is OOXML wrapped in a ZIP — magic must be "PK\003\004".
  defp read_docx(path) do
    case File.read(path) do
      {:ok, <<"PK", 0x03, 0x04, _::binary>> = bin} -> {:ok, bin}
      {:ok, bin} -> {:error, {:docx_bad_magic, byte_size(bin)}}
      {:error, reason} -> {:error, {:docx_read_failed, reason}}
    end
  end
end
