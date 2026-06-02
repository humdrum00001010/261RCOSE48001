defmodule Ecrits.Agent.Run do
  @moduledoc """
  In-memory record for one document-scoped agent run.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :document_id,
    :triggered_by_action_id,
    :previous_response_id,
    :message,
    :owner_id,
    :chat_thread_id,
    :started_at,
    :completed_at,
    :error,
    :model,
    :inserted_at,
    :updated_at,
    status: :running,
    turn_index: 0,
    tools_enabled: []
  ]
end
