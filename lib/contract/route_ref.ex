defmodule Contract.RouteRef do
  @moduledoc """
  A signed, opaque, time-bounded reference that authorizes an external client
  (Slack thread, MCP tool caller, deep link) to act on a specific document or
  matter without ever seeing a BEAM pid.

  Per SPEC.md §15 invariant 2: a BEAM pid MUST NOT be exposed externally as
  routing authority. RouteRefs only carry durable binary_ids — `matter_id`,
  `document_id`, plus a purpose string and a scope list. They are signed via
  `Phoenix.Token` so the server can verify them statelessly without a DB
  lookup.

  See SPEC.md §21 (Gateway).
  """

  @type purpose :: String.t()
  @type scope :: String.t() | atom()
  @type t :: %__MODULE__{
          matter_id: binary() | nil,
          document_id: binary() | nil,
          purpose: purpose(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          scopes: [scope()]
        }

  defstruct [
    :matter_id,
    :document_id,
    :purpose,
    :issued_at,
    :expires_at,
    :scopes
  ]
end
