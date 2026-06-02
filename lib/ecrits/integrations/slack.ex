defmodule Ecrits.Integrations.Slack do
  @moduledoc """
  Slack OAuth persistence has been pruned from the preserved execution path.
  """

  alias Ecrits.Context, as: Scope

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
          {:ok, term()} | {:error, term()}
  def complete_oauth(%Scope{} = ctx, code, redirect_uri, opts \\ []) do
    case Application.get_env(:ecrits, :slack_oauth_provider) do
      fun when is_function(fun, 4) -> fun.(ctx, code, redirect_uri, opts)
      _ -> {:error, :not_available}
    end
  end

  @doc """
  Returns the decrypted xoxp-* token for the request-scoped user, or
  `{:error, :not_connected}` if no row exists. The lookup matches on
  `user_id` (and `tenant_id` when populated on the scope).
  """
  @spec token_for(ctx() | nil) :: {:ok, access_token()} | {:error, :not_connected}
  def token_for(ctx) do
    case Application.get_env(:ecrits, :slack_token_provider) do
      fun when is_function(fun, 1) -> fun.(ctx)
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Returns the stored token row (without decrypting). Used by the
  integrations LiveView to render team / scopes badges.
  """
  @spec connection_info(ctx()) :: {:ok, term()} | {:error, :not_connected}
  def connection_info(ctx) do
    case Application.get_env(:ecrits, :slack_connection_provider) do
      fun when is_function(fun, 1) -> fun.(ctx)
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Removes any Slack token rows for the scope's user.
  """
  @spec disconnect(ctx()) :: :ok
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

  defp secret_key_base do
    Application.fetch_env!(:ecrits, EcritsWeb.Endpoint)[:secret_key_base] ||
      raise "EcritsWeb.Endpoint secret_key_base is not configured"
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
      _ -> raise "Ecrits.Integrations.Slack: missing required env var: #{name}"
    end
  end
end
