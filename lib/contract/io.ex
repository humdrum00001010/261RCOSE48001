defmodule Contract.IO do
  @moduledoc """
  Provider and export adapters: Upstage parse, OpenAI agent traffic,
  Cloudflare R2 storage, korean-law-mcp citation lookups, and export
  renderers.

  This module is a thin dispatcher to sub-modules under `Contract.IO.*`
  per SPEC.md §22.
  """

  alias Contract.Types, as: T

  @spec import_upload(T.ctx(), T.matter_id(), T.upload()) ::
          T.result(Contract.Action.t())
  def import_upload(ctx, matter_id, upload),
    do: Contract.IO.Upstage.import_upload(ctx, matter_id, upload)

  @spec parse_source(T.ctx(), source_ref :: String.t(), T.opts()) :: T.result(map())
  def parse_source(ctx, source_ref, opts \\ []),
    do: Contract.IO.Upstage.parse_source(ctx, source_ref, opts)

  @spec search_law(T.ctx(), query :: String.t(), T.opts()) :: T.result(list())
  def search_law(ctx, query, opts \\ []),
    do: Contract.IO.LawMCP.search_law(ctx, query, opts)

  @spec verify_citation(T.ctx(), citation :: String.t(), T.opts()) :: T.result(list())
  def verify_citation(ctx, citation, opts \\ []),
    do: Contract.IO.LawMCP.verify_citations(ctx, citation, opts)

  @spec export(T.ctx(), T.document_id(), format :: atom(), T.opts()) ::
          T.result(Contract.Export.t())
  def export(ctx, document_id, format, opts \\ []),
    do: Contract.IO.R2.export(ctx, document_id, format, opts)
end
