defmodule Contract.IO do
  @moduledoc """
  **Deprecated.** Per SPEC.md v0.5 §19–§20 the old `Contract.IO`
  façade has been split:

    * Object storage → `Contract.Blobs`
    * External services → `Contract.Providers`

  This module remains only as a thin forwarder so in-flight callers
  keep compiling while waves W2/W3/W6/W9/W12 migrate over. New code
  must NOT call `Contract.IO.*` directly.

  Per-function `@deprecated` attributes are intentionally omitted to
  keep `mix compile --warnings-as-errors` green during the split; the
  module-level deprecation in `@moduledoc deprecated:` is enough for
  ExDoc + IDE callouts. Migration owners are the wave subagents that
  reference each function (W2, W3, W6, W9, W12).

  Internal driver modules (`Contract.IO.R2`, `.Upstage`, `.OpenAI`,
  `.LawMCP`) stay where they are — they're the implementation layer
  Blobs/Providers delegate to.
  """
  @moduledoc deprecated:
               "Use Contract.Blobs (§19) or Contract.Providers (§20). " <>
                 "Forwarder kept for migration."

  alias Contract.Types, as: T

  # parse_document/2 path — kept as Upstage.import_upload so legacy
  # callers that still expect a `Command(:create_document)` keep working.
  @spec import_upload(T.ctx(), T.user_id() | nil, T.upload() | map()) ::
          T.result(Contract.Command.t())
  def import_upload(ctx, owner_id, upload),
    do: Contract.IO.Upstage.import_upload(ctx, owner_id, upload)

  @spec parse_source(T.ctx(), String.t(), T.opts()) :: T.result(map())
  def parse_source(ctx, source_ref, opts \\ []),
    do: Contract.IO.Upstage.parse_source(ctx, source_ref, opts)

  @spec search_law(T.ctx(), String.t(), T.opts()) :: T.result(list())
  def search_law(ctx, query, opts \\ []),
    do: Contract.Providers.search_law(ctx, query, opts)

  @spec verify_citation(T.ctx(), String.t(), T.opts()) :: T.result(list())
  def verify_citation(ctx, citation, opts \\ []),
    do: Contract.Providers.verify_citation(ctx, citation, opts)

  @spec export(T.ctx(), T.document_id(), atom(), T.opts()) ::
          T.result(Contract.Export.t())
  def export(ctx, document_id, format, opts \\ []),
    do: Contract.IO.R2.export(ctx, document_id, format, opts)
end
