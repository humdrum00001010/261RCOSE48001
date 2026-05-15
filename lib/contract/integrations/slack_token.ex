defmodule Contract.Integrations.SlackToken do
  @moduledoc """
  Ecto schema for a per-user Slack OAuth user-token row (Wave 6).

  The `:access_token` column stores ciphertext produced by
  `Plug.Crypto.encrypt/4` (AES-256 GCM + HMAC-SHA256 from
  `Plug.Crypto.MessageEncryptor`) keyed by the endpoint's
  `secret_key_base` and a fixed integration salt. The plaintext xoxp-*
  Slack user token NEVER lands in this column.

  See `Contract.Integrations.Slack` for the encrypt / decrypt + lifecycle
  helpers and `priv/repo/migrations/20260515170000_create_slack_tokens.exs`
  for the table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "slack_tokens" do
    field :user_id, :binary_id
    field :tenant_id, :binary_id
    field :slack_team_id, :string
    field :slack_user_id, :string
    field :access_token, :binary
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :raw_response, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required ~w(user_id slack_team_id slack_user_id access_token)a
  @optional ~w(tenant_id scopes expires_at raw_response)a

  @doc """
  Changeset used by `Contract.Integrations.Slack.complete_oauth/3`. The
  caller is responsible for encrypting the access_token before passing
  it in (we don't want plaintext touching the changeset either).
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:user_id, :slack_team_id],
      name: :slack_tokens_user_id_slack_team_id_index
    )
  end
end
