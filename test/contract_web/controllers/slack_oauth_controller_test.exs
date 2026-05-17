defmodule ContractWeb.SlackOAuthControllerTest do
  @moduledoc """
  Tests for `/auth/slack/{start,callback,disconnect}` — Wave 6.

  We do NOT actually exchange a real Slack code; the callback test
  patches the `Contract.Integrations.Slack` module's HTTP layer by
  inserting a stored token directly and verifying the state-CSRF gate
  + redirect behavior.
  """
  # NOT async — shares SLACK_* env vars with the context-level test
  # at test/contract/integrations/slack_test.exs.
  use ContractWeb.ConnCase, async: false

  alias Contract.Integrations.Slack
  alias Contract.Integrations.SlackToken
  alias Contract.Repo

  setup do
    System.put_env("SLACK_CLIENT_ID", "test-client-id")
    System.put_env("SLACK_CLIENT_SECRET", "test-client-secret")
    System.put_env("SLACK_USER_AUTHORIZE_URL", "https://slack.com/oauth/v2_user/authorize")
    System.put_env("SLACK_USER_TOKEN_URL", "https://slack.com/api/oauth.v2.user.access")

    System.put_env(
      "SLACK_MCP_USER_SCOPES",
      "search:read.public,channels:history"
    )

    System.put_env("SLACK_MCP_WRITE_SCOPES", "chat:write")
    :ok
  end

  describe "GET /auth/slack/start" do
    setup :register_and_log_in_user

    test "redirects to slack.com with the expected query params + stashes state",
         %{conn: conn} do
      conn = get(conn, ~p"/auth/slack/start")

      assert redirected_to(conn, 302) =~ "https://slack.com/oauth/v2_user/authorize?"

      target = redirected_to(conn)
      %URI{query: query_str} = URI.parse(target)
      params = URI.decode_query(query_str)

      assert params["client_id"] == "test-client-id"
      assert params["redirect_uri"] =~ "/auth/slack/callback"
      assert params["state"] != nil and params["state"] != ""
      assert params["user_scope"] =~ "search:read.public"
      refute params["user_scope"] =~ "chat:write"

      assert get_session(conn, :slack_oauth_state) == params["state"]
    end

    test "includes write scopes when ?write=1", %{conn: conn} do
      conn = get(conn, ~p"/auth/slack/start?write=1")
      target = redirected_to(conn)
      %URI{query: query_str} = URI.parse(target)
      params = URI.decode_query(query_str)

      assert params["user_scope"] =~ "chat:write"
    end

    test "redirects anonymous users to log in", %{} do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/auth/slack/start")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "GET /auth/slack/callback" do
    setup :register_and_log_in_user

    test "CSRF state gate: mismatched returns 'invalid oauth state', missing returns 'missing'",
         %{conn: conn} do
      conn1 = get(conn, ~p"/auth/slack/start")
      state = get_session(conn1, :slack_oauth_state)
      assert is_binary(state)

      mismatch =
        conn1
        |> recycle()
        |> Plug.Test.init_test_session(%{slack_oauth_state: state})
        |> get(~p"/auth/slack/callback?code=somecode&state=WRONG")

      assert response(mismatch, 403) =~ "invalid oauth state"

      missing =
        conn
        |> get(~p"/auth/slack/callback?code=somecode&state=anything")

      assert response(missing, 403) =~ "missing oauth state"
    end

    test "with error param redirects to /settings/integrations with a flash",
         %{conn: conn} do
      conn = get(conn, ~p"/auth/slack/callback?error=access_denied")
      assert redirected_to(conn) == ~p"/settings/integrations"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "access_denied"
    end
  end

  describe "POST /auth/slack/disconnect" do
    setup :register_and_log_in_user

    test "removes the token row + redirects to /settings/integrations",
         %{conn: conn, user: user} do
      # Insert a row directly so we can verify deletion without an OAuth.
      ciphertext = Slack.encrypt("xoxp-test-token")

      {:ok, _row} =
        %SlackToken{}
        |> SlackToken.changeset(%{
          user_id: user.id,
          slack_team_id: "T01",
          slack_user_id: "U01",
          access_token: ciphertext,
          scopes: ["users:read"]
        })
        |> Repo.insert()

      conn = post(conn, ~p"/auth/slack/disconnect", %{})
      assert redirected_to(conn) == ~p"/settings/integrations"

      refute Repo.get_by(SlackToken, user_id: user.id)
    end
  end
end
