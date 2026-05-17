defmodule Contract.Providers do
  @moduledoc """
  External-service façade (SPEC.md v0.5 §20).

  This module is the **only** public surface for outbound API calls:
  Upstage Document Parse, OpenAI Responses streaming, Korea-Law-MCP,
  and the export renderers. It does no storage — Blobs handles that.

  ## Provider mapping (SPEC §20)

      parse_document/2       → Upstage Document Parse
      stream_agent/3         → OpenAI Responses (streaming)
      search_law/2           → Korea Law MCP
      get_law_text/2         → Korea Law MCP
      search_precedents/2    → Korea Law MCP
      verify_citation/2      → Korea Law MCP
      render_export/3        → PDF / HWPX / DOCX / Markdown / lawyer_packet

  ## Pipeline (SPEC §21)

      upload → Blobs.put_upload → SourceDocument → Providers.parse_document
            → parser_snapshot → regions → source_claims

  Internally delegates to `Contract.IO.Upstage`, `Contract.IO.OpenAI`,
  `Contract.IO.LawMCP`, and `Contract.Export.Renderer`. The sub-modules
  are still useful as drivers; this façade is what callers (Studio,
  Session, workers, Live components) should depend on going forward.
  """

  alias Contract.BlobRef
  alias Contract.Blobs
  alias Contract.EvidenceSnapshots
  alias Contract.IO.LawMCP
  alias Contract.IO.OpenAI
  alias Contract.Types, as: T

  # ---------------------------------------------------------------------------
  # parse_document/2 — Upstage Document Parse
  # ---------------------------------------------------------------------------

  @doc """
  Parses the document referenced by `blob_ref` with Upstage Document
  Parse and returns normalized `regions` plus a `parser_snapshot_ref`
  (the BlobRef id) when the caller asked us to persist the raw parser
  payload.

  Returns:

      {:ok, %{regions: [%{kind:, region_id:, page:, bbox:, raw_text:}, ...],
              parser_snapshot_ref: blob_ref_id | nil,
              raw: upstage_response}}

  Opts:
    * `:endpoint`, `:api_key`, `:timeout`, `:ocr`, `:coordinates`,
      `:output_formats`, `:model`, `:req_opts` — forwarded to the
      Upstage driver.
    * `:persist_snapshot?` — when `true` and a ctx is given, the raw
      Upstage response is uploaded to R2 via `Blobs.put/3` and the
      returned `:parser_snapshot_ref` is the BlobRef id.
  """
  @spec parse_document(
          T.ctx() | nil,
          BlobRef.t() | %{optional(:object_key) => String.t()} | String.t() | binary(),
          keyword()
        ) ::
          T.result(%{
            regions: [map()],
            parser_snapshot_ref: String.t() | nil,
            raw: map()
          })
  def parse_document(blob_or_path), do: parse_document(nil, blob_or_path, [])

  def parse_document(blob_or_path, opts) when is_list(opts),
    do: parse_document(nil, blob_or_path, opts)

  def parse_document(ctx, blob_or_path), do: parse_document(ctx, blob_or_path, [])

  def parse_document(ctx, blob_or_path, opts) do
    with {:ok, path_or_bytes} <- resolve_source(blob_or_path),
         {:ok, parsed} <- upstage_driver().parse(path_or_bytes, opts) do
      regions = elements_to_regions(parsed.elements)

      snapshot_ref =
        if Keyword.get(opts, :persist_snapshot?, false) do
          maybe_persist_snapshot(ctx, parsed.raw, opts)
        else
          nil
        end

      {:ok, %{regions: regions, parser_snapshot_ref: snapshot_ref, raw: parsed.raw}}
    end
  end

  # ---------------------------------------------------------------------------
  # stream_agent/3 — OpenAI Responses streaming
  # ---------------------------------------------------------------------------

  @doc """
  Streams an OpenAI Responses-API completion. Forwards `params` to the
  driver (model defaults to `gpt-5-mini`, reasoning effort `"high"` —
  see `Contract.IO.OpenAI`).

  The `handler` is invoked for each normalized event
  (`%{type: ..., data: ...}`) — pass `nil` to receive the raw stream
  instead.

  Returns `{:ok, %{stream:, task_pid:}}` (or, when `handler` is a
  callable, `{:ok, %{task_pid:}}` after the stream has been spawned for
  side-effect consumption).
  """
  @spec stream_agent(T.ctx() | nil, map(), (map() -> any()) | nil, keyword()) ::
          {:ok, %{stream: Enumerable.t(), task_pid: pid()}} | {:error, term()}
  def stream_agent(params, handler \\ nil, opts \\ []),
    do: stream_agent(nil, params, handler, opts)

  def stream_agent(ctx, params, handler, opts) when is_map(params) do
    opts = if ctx, do: Keyword.put_new(opts, :ctx, ctx), else: opts

    case OpenAI.stream_chat(params, opts) do
      {:ok, %{stream: stream, task_pid: pid}} when is_function(handler) ->
        Enum.each(stream, handler)
        {:ok, %{stream: stream, task_pid: pid}}

      {:ok, _} = ok ->
        ok

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Korea Law MCP — search_law / get_law_text / search_precedents / verify_citation
  # ---------------------------------------------------------------------------

  @doc """
  Searches the Korea Law MCP corpus. Returns a list of law records
  suitable for use as `EvidenceSnapshot` source material (each entry
  carries `law_id` / `mst` / `title` etc.).
  """
  @spec search_law(T.ctx() | nil, String.t(), keyword()) :: T.result(list())
  def search_law(query) when is_binary(query), do: search_law(nil, query, [])

  def search_law(query, opts) when is_binary(query) and is_list(opts),
    do: search_law(nil, query, opts)

  def search_law(ctx, query) when is_binary(query), do: search_law(ctx, query, [])

  def search_law(ctx, query, opts) when is_binary(query) do
    args = %{"query" => query} |> maybe_put("limit", Keyword.get(opts, :limit))

    with {:ok, items} <- LawMCP.search_law(query, opts) do
      _ = capture_evidence(ctx, "law_mcp.search_law", args, items, opts)
      {:ok, items}
    end
  end

  @doc """
  Fetches the full law text by `law_ref` (a `law_id` / `mst` /
  short-name accepted by the MCP `get_law_text` tool).
  """
  @spec get_law_text(T.ctx() | nil, String.t(), keyword()) :: T.result(term())
  def get_law_text(law_ref) when is_binary(law_ref), do: get_law_text(nil, law_ref, [])

  def get_law_text(law_ref, opts) when is_binary(law_ref) and is_list(opts),
    do: get_law_text(nil, law_ref, opts)

  def get_law_text(ctx, law_ref) when is_binary(law_ref), do: get_law_text(ctx, law_ref, [])

  def get_law_text(ctx, law_ref, opts) when is_binary(law_ref) do
    args = %{"law_ref" => law_ref}

    case LawMCP.call("get_law_text", args, opts) do
      {:ok, result} ->
        _ = capture_evidence(ctx, "law_mcp.get_law_text", args, result, opts)
        {:ok, result}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Searches Korean case-law / precedents by free-text query.
  """
  @spec search_precedents(T.ctx() | nil, String.t(), keyword()) :: T.result(list())
  def search_precedents(query) when is_binary(query), do: search_precedents(nil, query, [])

  def search_precedents(query, opts) when is_binary(query) and is_list(opts),
    do: search_precedents(nil, query, opts)

  def search_precedents(ctx, query) when is_binary(query), do: search_precedents(ctx, query, [])

  def search_precedents(ctx, query, opts) when is_binary(query) do
    args =
      %{"query" => query}
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case LawMCP.call("search_precedents", args, opts) do
      {:ok, list} when is_list(list) ->
        _ = capture_evidence(ctx, "law_mcp.search_precedents", args, list, opts)
        {:ok, list}

      {:ok, %{"items" => items} = result} when is_list(items) ->
        _ = capture_evidence(ctx, "law_mcp.search_precedents", args, result, opts)
        {:ok, items}

      {:ok, other} ->
        items = List.wrap(other)
        _ = capture_evidence(ctx, "law_mcp.search_precedents", args, items, opts)
        {:ok, items}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Verifies citations inside legal text (or a list of citations).
  Returns a list of `%{"citation", "valid", ...}` maps.
  """
  @spec verify_citation(T.ctx() | nil, String.t() | [String.t()], keyword()) ::
          T.result(list())
  def verify_citation(citation), do: verify_citation(nil, citation, [])

  def verify_citation(citation, opts) when is_list(opts),
    do: verify_citation(nil, citation, opts)

  def verify_citation(ctx, citation), do: verify_citation(ctx, citation, [])

  def verify_citation(ctx, citation, opts) when is_binary(citation) do
    args = %{"text" => citation}

    with {:ok, items} <- LawMCP.verify_citations(citation, opts) do
      _ = capture_evidence(ctx, "law_mcp.verify_citations", args, items, opts)
      {:ok, items}
    end
  end

  def verify_citation(ctx, citations, opts) when is_list(citations) do
    args = %{"text" => Enum.join(citations, "\n")}

    with {:ok, items} <- LawMCP.verify_citations(citations, opts) do
      _ = capture_evidence(ctx, "law_mcp.verify_citations", args, items, opts)
      {:ok, items}
    end
  end

  # ---------------------------------------------------------------------------
  # render_export/3 — format dispatcher
  # ---------------------------------------------------------------------------

  @supported_formats [:hwpx, :docx, :pdf, :markdown, :md, :lawyer_packet]

  @doc """
  Renders `document_state` to the requested `format`. Returns
  `{:ok, bytes, content_type}`.

  Formats:

    * `:hwpx`, `:docx`, `:pdf` — dispatch to
      `Contract.Export.<Format>` via `Contract.Export.Renderer.render/3`.
    * `:markdown` / `:md` — render deterministic Markdown.
    * `:lawyer_packet` — render a deterministic Markdown lawyer packet.

  Unknown formats return `{:error, {:unsupported_format, format}}`.
  """
  @spec render_export(T.ctx() | nil, term(), atom(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def render_export(document_state, format),
    do: render_export(nil, document_state, format, [])

  def render_export(document_state, format, opts) when is_list(opts),
    do: render_export(nil, document_state, format, opts)

  def render_export(ctx, document_state, format),
    do: render_export(ctx, document_state, format, [])

  def render_export(_ctx, %Contract.Runtime.State{} = state, format, opts)
      when format in @supported_formats do
    Contract.Export.Renderer.render(state, normalize_export_format(format), opts)
  end

  def render_export(_ctx, %{document_id: _} = payload, format, _opts)
      when format in [:markdown, :md, :pdf, :docx] do
    # Legacy 1-arg renderer path — used when the caller only has a
    # document_id+format pair (no Runtime.State in scope).
    Contract.Export.Renderer.render(Map.put(payload, :format, normalize_export_format(format)))
  end

  def render_export(_ctx, _state, format, _opts), do: {:error, {:unsupported_format, format}}

  defp normalize_export_format(:md), do: :markdown
  defp normalize_export_format(format), do: format

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp upstage_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:upstage, Contract.IO.Upstage)
  end

  defp resolve_source(%BlobRef{object_key: key}) when is_binary(key), do: fetch_r2(key)
  defp resolve_source(%{object_key: key}) when is_binary(key), do: fetch_r2(key)
  defp resolve_source(%{"object_key" => key}) when is_binary(key), do: fetch_r2(key)
  defp resolve_source(%{key: key}) when is_binary(key), do: fetch_r2(key)
  defp resolve_source(%{"key" => key}) when is_binary(key), do: fetch_r2(key)

  defp resolve_source("r2://" <> rest) do
    [_bucket, key] = String.split(rest, "/", parts: 2)
    fetch_r2(key)
  end

  defp resolve_source(path_or_bytes) when is_binary(path_or_bytes), do: {:ok, path_or_bytes}
  defp resolve_source(other), do: {:error, {:invalid_source, other}}

  defp fetch_r2(key) do
    case Blobs.get(nil, key) do
      {:ok, body} -> {:ok, body}
      {:error, _} = err -> err
    end
  end

  # Normalizes Upstage `elements[]` to the v0.5 region shape required by
  # `SourceDocument.regions` (SPEC §7.3): `%{kind, region_id, page,
  # bbox, raw_text}` with the original Upstage attrs tucked into
  # `:attrs` for downstream renderers.
  defp elements_to_regions(elements) when is_list(elements) do
    Enum.map(elements, &element_to_region/1)
  end

  defp element_to_region(elem) do
    category = Map.get(elem, "category", "paragraph")
    content_map = Map.get(elem, "content", %{})

    raw_text =
      Map.get(content_map, "text") || Map.get(content_map, "markdown") ||
        Map.get(content_map, "html") || ""

    %{
      kind: map_category(category),
      region_id: region_id_from(elem),
      page: Map.get(elem, "page"),
      bbox: Map.get(elem, "coordinates"),
      raw_text: raw_text,
      attrs: %{
        "category" => category,
        "html" => Map.get(content_map, "html"),
        "markdown" => Map.get(content_map, "markdown")
      }
    }
  end

  defp region_id_from(%{"id" => id}) when is_integer(id), do: "region:#{id}"
  defp region_id_from(%{"id" => id}) when is_binary(id), do: id
  defp region_id_from(_), do: "region:" <> Ecto.UUID.generate()

  defp map_category("paragraph"), do: :paragraph
  defp map_category("list"), do: :list
  defp map_category("list_item"), do: :list_item
  defp map_category("table"), do: :table
  defp map_category("figure"), do: :figure
  defp map_category("caption"), do: :caption
  defp map_category("footnote"), do: :footnote
  defp map_category("header"), do: :header
  defp map_category("footer"), do: :footer
  defp map_category("equation"), do: :equation

  defp map_category("heading" <> _), do: :heading
  defp map_category(_), do: :paragraph

  defp maybe_persist_snapshot(_ctx, raw, opts) when is_map(raw) do
    snapshot_id = Ecto.UUID.generate()
    key = "parser-snapshots/#{snapshot_id}.json"

    case Blobs.put(
           nil,
           key,
           Jason.encode!(raw),
           Keyword.put_new(opts, :content_type, "application/json")
         ) do
      {:ok, _} -> snapshot_id
      _ -> nil
    end
  end

  defp maybe_persist_snapshot(_ctx, _raw, _opts), do: nil

  defp capture_evidence(ctx, provider, query, result, opts) do
    EvidenceSnapshots.capture(ctx, provider, query, result,
      chat_thread_id: Keyword.get(opts, :chat_thread_id),
      document_id: Keyword.get(opts, :document_id),
      source_document_id: Keyword.get(opts, :source_document_id)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
