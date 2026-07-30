defmodule Ecrits.Workspace.Session.Agent do
  @moduledoc """
  Session-owned agent state.

  The canonical workspace session persists this shape for an agent. The ACP
  runner can be restarted or resumed from it, but does not own this state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Agent.Dialog

  @primary_key false

  @type id :: String.t()
  @type role :: :foreground | :background
  @type provider_id :: String.t()
  @type adapter_opts :: keyword()
  @type transcript_item :: Dialog.t()
  @type queued_turn :: map()
  @type current_turn :: %{id: String.t(), status: atom()} | map()
  @type mcp_server :: %{required(String.t()) => String.t()}

  @type ref :: %{
          pid: pid(),
          role: role()
        }

  @type t :: %__MODULE__{
          id: id(),
          role: role(),
          pid: pid() | nil,
          provider: provider_id() | nil,
          provider_session_id: String.t() | nil,
          title: String.t() | nil,
          title_user_edited?: boolean(),
          transcript: [transcript_item()],
          queue: [queued_turn()],
          current_turn: current_turn() | nil,
          adapter_opts: adapter_opts(),
          mcp_servers: [mcp_server()]
        }

  embedded_schema do
    field :id, :string
    field :role, Ecto.Enum, values: [:foreground, :background], default: :foreground
    field :pid, :any, virtual: true
    field :provider, :string
    field :provider_session_id, :string
    field :title, :string
    field :title_user_edited?, :boolean, default: false
    embeds_many :transcript, Dialog, on_replace: :delete
    field :queue, {:array, :map}, default: []
    field :current_turn, :map
    field :adapter_opts, :any, virtual: true, default: []
    field :mcp_servers, {:array, :map}, default: []
  end

  @fields [
    :id,
    :role,
    :provider,
    :provider_session_id,
    :title,
    :title_user_edited?,
    :queue,
    :current_turn,
    :mcp_servers
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = agent, attrs) when is_map(attrs) do
    agent
    |> cast(attrs, @fields)
    |> cast_embed(:transcript, with: &Dialog.changeset/2)
  end
end
