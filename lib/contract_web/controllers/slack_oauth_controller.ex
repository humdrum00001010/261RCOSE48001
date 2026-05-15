defmodule ContractWeb.SlackOAuthController do
  @moduledoc """
  Slack OAuth user-token flow (Wave 6).

  Routes:

    * `GET  /auth/slack/start`      — generates a CSRF state, stashes it
      in the session, redirects to the Slack v2 user-authorize URL.
    * `GET  /auth/slack/callback`   — verifies CSRF + exchanges the code
      for an xoxp-* user token via `Contract.Integrations.Slack`.
    * `POST /auth/slack/disconnect` — wipes the user's stored token.

  All three routes live behind `:require_authenticated_user` so
  `conn.assigns.current_scope.user` is always populated.

  Slack ingress (`/slack/events` / `/actions` / `/commands`) stays at
  501. This controller is OUTBOUND only.
  """
  use ContractWeb, :controller

  alias Contract.Integrations.Slack

  @session_state_key :slack_oauth_state
  @session_write_key :slack_oauth_write

  def start(conn, params) do
    scope = conn.assigns.current_scope
    write? = params["write"] == "1"

    {:ok, %{authorize_url: url, state: state}} =
      Slack.start_oauth(scope, callback_url(conn), write?: write?)

    conn
    |> put_session(@session_state_key, state)
    |> put_session(@session_write_key, write?)
    |> redirect(external: url)
  end

  def callback(conn, %{"error" => error}) do
    conn
    |> delete_session(@session_state_key)
    |> delete_session(@session_write_key)
    |> put_flash(:error, "Slack 연결 실패: #{error}")
    |> redirect(to: ~p"/settings/integrations")
  end

  def callback(conn, %{"code" => code, "state" => state} = _params) do
    expected = get_session(conn, @session_state_key)
    scope = conn.assigns.current_scope

    cond do
      is_nil(expected) or expected == "" ->
        conn |> put_status(:forbidden) |> text("missing oauth state")

      not Plug.Crypto.secure_compare(state, expected) ->
        conn |> put_status(:forbidden) |> text("invalid oauth state")

      true ->
        case Slack.complete_oauth(scope, code, callback_url(conn)) do
          {:ok, _row} ->
            conn
            |> delete_session(@session_state_key)
            |> delete_session(@session_write_key)
            |> put_flash(:info, "Slack 연결 완료")
            |> redirect(to: ~p"/settings/integrations")

          {:error, reason} ->
            conn
            |> delete_session(@session_state_key)
            |> delete_session(@session_write_key)
            |> put_flash(:error, "Slack 연결 실패: #{inspect(reason)}")
            |> redirect(to: ~p"/settings/integrations")
        end
    end
  end

  def callback(conn, _params) do
    conn |> put_status(:bad_request) |> text("missing code or state")
  end

  def disconnect(conn, _params) do
    Slack.disconnect(conn.assigns.current_scope)

    conn
    |> put_flash(:info, "Slack 연결 해제됨")
    |> redirect(to: ~p"/settings/integrations")
  end

  defp callback_url(conn) do
    url(conn, ~p"/auth/slack/callback")
  end
end
