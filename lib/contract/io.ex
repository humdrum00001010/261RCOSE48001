defmodule Contract.IO do
  @moduledoc """
  Provider and export adapters: Upstage parse, OpenAI agent traffic,
  Cloudflare R2 storage, korean-law-mcp citation lookups, and export
  renderers.

  Track A2 (feat/io) fills these out. See SPEC.md §22.
  """

  alias Contract.Types, as: T

  @type export :: term()

  @spec import_upload(T.ctx(), T.matter_id(), T.upload()) :: T.result(Contract.Action.t())
  def import_upload(_ctx, _matter_id, _upload),
    do: raise("Contract.IO.import_upload/3 not implemented")

  @spec parse_source(T.ctx(), source_ref :: String.t(), T.opts()) :: T.result(map())
  def parse_source(_ctx, _source_ref, _opts),
    do: raise("Contract.IO.parse_source/3 not implemented")

  @spec search_law(T.ctx(), query :: String.t(), T.opts()) :: T.result(map())
  def search_law(_ctx, _query, _opts),
    do: raise("Contract.IO.search_law/3 not implemented")

  @spec verify_citation(T.ctx(), citation :: String.t(), T.opts()) :: T.result(map())
  def verify_citation(_ctx, _citation, _opts),
    do: raise("Contract.IO.verify_citation/3 not implemented")

  @spec export(T.ctx(), T.document_id(), format :: atom(), T.opts()) :: T.result(export())
  def export(_ctx, _document_id, _format, _opts),
    do: raise("Contract.IO.export/4 not implemented")
end
