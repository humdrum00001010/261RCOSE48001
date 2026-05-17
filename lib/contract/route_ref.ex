defmodule Contract.RouteRef do
  @moduledoc """
  A signed, opaque, time-bounded reference that authorizes an external client
  (Slack thread, MCP tool caller, deep link) to act on a specific document without ever seeing a BEAM pid.

  Per SPEC.md §15 invariant 2: a BEAM pid MUST NOT be exposed externally as
  routing authority. RouteRefs only carry durable binary_ids — `document_id`, plus a purpose string and a scope list. They are signed via
  `Phoenix.Token` so the server can verify them statelessly without a DB
  lookup.

  See SPEC.md §21 (Gateway).
  """

  @type purpose :: String.t()
  @type scope :: String.t() | atom()
  @type t :: %__MODULE__{
          document_id: binary() | nil,
          user_id: binary() | nil,
          chat_thread_id: binary() | nil,
          agent_run_id: binary() | nil,
          base_revision: integer() | nil,
          purpose: purpose(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          scopes: [scope()]
        }

  defstruct [
    :document_id,
    :user_id,
    :chat_thread_id,
    :agent_run_id,
    :base_revision,
    :purpose,
    :issued_at,
    :expires_at,
    :scopes
  ]
end
