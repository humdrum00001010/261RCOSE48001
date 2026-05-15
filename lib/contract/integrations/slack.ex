defmodule Contract.Integrations.Slack do
  @moduledoc """
  Slack OAuth user-token flow + decrypted-token accessor for the
  Slack-hosted MCP (Wave 6).

  This module owns:

    * `start_oauth/2` — builds the Slack v2 user-OAuth authorize URL with
      a freshly-minted CSRF state token and the scope set from `.env`'s
      `SLACK_MCP_USER_SCOPES` (+ optionally `SLACK_MCP_WRITE_SCOPES`).
    * `complete_oauth/3` — exchanges an authorization code for an xoxp-*
      user token at `SLACK_USER_TOKEN_URL`, encrypts the token via
      `Plug.Crypto.encrypt/4` (keyed by `secret_key_base` + a fixed
      integration salt), upserts a `slack_tokens` row scoped to the
      `Contract.Context` user.
    * `token_for/1` — decrypts the stored token for a request-scoped
      `Contract.Context`. Returns `{:error, :not_connected}` if no row
      exists, so callers can no-op the Slack MCP tool attachment.
    * `disconnect/1` — deletes the user's stored token.

  ## Encryption

  Tokens are encrypted with `Plug.Crypto.encrypt(secret_key_base,
  @salt, token)` using the running endpoint's `secret_key_base`. The
  salt is per-feature (`"slack-integration v1"`) so rotating it would
  invalidate every stored token cleanly. Plaintext xoxp-* tokens never
  hit the DB. See `Contract.Integrations.SlackToken` for the column
  layout.

  ## Per-tenant scoping

  Stored rows carry the `tenant_id` from the `Contract.Context` for
  future multi-tenant queries; `token_for/1` matches on `user_id`
  AND (when set) `tenant_id` so a single user could in theory hold
  separate Slack tokens per tenant. Today every confirmed user is
  in a single (nil) tenant — see `Contract.Context`. The migration
  permits NULL tenant_id which is what we get today.

  ## NOT in scope

  Slack ingress (`/slack/events`, `/slack/actions`, `/slack/commands`)
  STAYS at 501 per the project Slack-MCP memory directive. This wave
  is OUTBOUND only.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Context, as: Scope
  alias Contract.Integrations.SlackToken
  alias Contract.Repo

  @encryption_salt "slack-integration v1"
  @csrf_byte_size 24

  @type ctx :: Scope.t()
  @type access_token :: String.t()

  @doc """
  Builds the Slack authorize URL and the CSRF state token the caller
  must persist (typically in `put_session(:slack_oauth_state, state)`).

  Options:
    * `:write?` — `true` to include `SLACK_MCP_WRITE_SCOPES` in the
      requested scope set; defaults to `false` (read-only install).
    * `:scopes` — explicit scope list, bypasses .env-derived defaults.
  """
  @spec start_oauth(ctx(), String.t(), keyword()) ::
          {:ok, %{authorize_url: String.t(), state: String.t(), scopes: [String.t()]}}
  def start_oauth(%Scope{} = _ctx, redirect_uri, opts \\ []) when is_binary(redirect_uri) do
    state = generate_state()
    scopes = resolve_scopes(opts)

    params =
      URI.encode_query(%{
        "client_id" => fetch_env!("SLACK_CLIENT_ID"),
        "user_scope" => Enum.join(scopes, ","),
        "redirect_uri" => redirect_uri,
        "state" => state
      })

    url = fetch_env!("SLACK_USER_AUTHORIZE_URL") <> "?" <> params

    {:ok, %{authorize_url: url, state: state, scopes: scopes}}
  end

  @doc """
  Exchanges an authorization code for an xoxp-* user token at Slack's
  `oauth.v2.user.access` endpoint, encrypts the token, and upserts a
  `slack_tokens` row scoped to `ctx.user.id`.

  The HTTP transport is `Req` so the call is testable via `Req.Test`.
  """
  @spec complete_oauth(ctx(), String.t(), String.t(), keyword()) ::
          {:ok, SlackToken.t()} | {:error, term()}
  def complete_oauth(%Scope{user: %{id: user_id} = _user} = ctx, code, redirect_uri, opts \\ [])
      when is_binary(code) and is_binary(redirect_uri) do
    with {:ok, payload} <- exchange_code(code, redirect_uri, opts),
         :ok <- verify_payload(payload),
         {:ok, attrs} <- extract_token_attrs(payload, user_id, ctx) do
      upsert_token(attrs)
    end
  end

  @doc """
  Returns the decrypted xoxp-* token for the request-scoped user, or
  `{:error, :not_connected}` if no row exists. The lookup matches on
  `user_id` (and `tenant_id` when populated on the scope).
  """
  @spec token_for(ctx() | nil) :: {:ok, access_token()} | {:error, :not_connected}
  def token_for(%Scope{user: %{id: user_id}} = ctx) do
    case fetch_row(user_id, ctx.tenant) do
      nil -> {:error, :not_connected}
      %SlackToken{access_token: ciphertext} -> decrypt(ciphertext)
    end
  end

  def token_for(_), do: {:error, :not_connected}

  @doc """
  Returns the stored token row (without decrypting). Used by the
  integrations LiveView to render team / scopes badges.
  """
  @spec connection_info(ctx()) :: {:ok, SlackToken.t()} | {:error, :not_connected}
  def connection_info(%Scope{user: %{id: user_id}} = ctx) do
    case fetch_row(user_id, ctx.tenant) do
      nil -> {:error, :not_connected}
      %SlackToken{} = row -> {:ok, row}
    end
  end

  def connection_info(_), do: {:error, :not_connected}

  @doc """
  Removes any Slack token rows for the scope's user.
  """
  @spec disconnect(ctx()) :: :ok
  def disconnect(%Scope{user: %{id: user_id}}) do
    from(t in SlackToken, where: t.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  def disconnect(_), do: :ok

  @doc """
  Returns the configured read-only scopes from `.env`.
  """
  @spec read_scopes() :: [String.t()]
  def read_scopes do
    "SLACK_MCP_USER_SCOPES"
    |> System.get_env("")
    |> split_scopes()
  end

  @doc """
  Returns the configured write scopes from `.env` (gated by the user
  consent flag in `start_oauth/3`).
  """
  @spec write_scopes() :: [String.t()]
  def write_scopes do
    "SLACK_MCP_WRITE_SCOPES"
    |> System.get_env("")
    |> split_scopes()
  end

  # --- internals ---------------------------------------------------------

  defp resolve_scopes(opts) do
    cond do
      scopes = Keyword.get(opts, :scopes) ->
        List.wrap(scopes)

      Keyword.get(opts, :write?, false) ->
        read_scopes() ++ write_scopes()

      true ->
        read_scopes()
    end
  end

  defp split_scopes(""), do: []
  defp split_scopes(nil), do: []

  defp split_scopes(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp generate_state do
    :crypto.strong_rand_bytes(@csrf_byte_size) |> Base.url_encode64(padding: false)
  end

  defp exchange_code(code, redirect_uri, opts) do
    url = Keyword.get(opts, :token_url) || fetch_env!("SLACK_USER_TOKEN_URL")
    client_id = fetch_env!("SLACK_CLIENT_ID")
    client_secret = fetch_env!("SLACK_CLIENT_SECRET")

    body = %{
      "code" => code,
      "client_id" => client_id,
      "client_secret" => client_secret,
      "redirect_uri" => redirect_uri
    }

    req_opts =
      [
        url: url,
        method: :post,
        form: body,
        headers: [{"accept", "application/json"}]
      ]
      |> Keyword.merge(Keyword.get(opts, :req_opts, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  # Slack returns 200 + {"ok": false, "error": "..."} on auth failures.
  defp verify_payload(%{"ok" => true}), do: :ok
  defp verify_payload(%{"ok" => false, "error" => err}), do: {:error, {:slack_error, err}}
  defp verify_payload(other), do: {:error, {:malformed_response, other}}

  defp extract_token_attrs(payload, user_id, ctx) do
    auth_user = payload["authed_user"] || %{}

    access_token = auth_user["access_token"] || payload["access_token"]
    slack_user_id = auth_user["id"] || payload["user_id"]
    team = payload["team"] || %{}
    slack_team_id = team["id"] || payload["team_id"]
    scope_str = auth_user["scope"] || payload["scope"] || ""

    cond do
      not is_binary(access_token) or access_token == "" ->
        {:error, {:malformed_response, payload}}

      not is_binary(slack_team_id) or slack_team_id == "" ->
        {:error, {:malformed_response, payload}}

      true ->
        {:ok,
         %{
           user_id: user_id,
           tenant_id: ctx.tenant,
           slack_team_id: slack_team_id,
           slack_user_id: slack_user_id || "",
           access_token: encrypt(access_token),
           scopes: split_scopes(scope_str),
           expires_at: nil,
           raw_response: payload
         }}
    end
  end

  defp upsert_token(attrs) do
    case Repo.get_by(SlackToken, user_id: attrs.user_id, slack_team_id: attrs.slack_team_id) do
      nil -> %SlackToken{}
      existing -> existing
    end
    |> SlackToken.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp fetch_row(user_id, nil) do
    Repo.one(
      from t in SlackToken,
        where: t.user_id == ^user_id,
        order_by: [desc: t.updated_at],
        limit: 1
    )
  end

  defp fetch_row(user_id, tenant_id) do
    Repo.one(
      from t in SlackToken,
        where: t.user_id == ^user_id and t.tenant_id == ^tenant_id,
        order_by: [desc: t.updated_at],
        limit: 1
    )
  end

  # --- crypto ------------------------------------------------------------

  defp secret_key_base do
    Application.fetch_env!(:contract, ContractWeb.Endpoint)[:secret_key_base] ||
      raise "ContractWeb.Endpoint secret_key_base is not configured"
  end

  @doc false
  @spec encrypt(String.t()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    Plug.Crypto.encrypt(secret_key_base(), @encryption_salt, plaintext)
  end

  @doc false
  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(ciphertext) when is_binary(ciphertext) do
    case Plug.Crypto.decrypt(secret_key_base(), @encryption_salt, ciphertext, max_age: :infinity) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_env!(name) do
    case System.get_env(name) do
      val when is_binary(val) and val != "" -> val
      _ -> raise "Contract.Integrations.Slack: missing required env var: #{name}"
    end
  end
end
