defmodule Contract.Integrations.SlackTest do
  @moduledoc """
  Tests for the Slack OAuth user-token context (Wave 6).

  We do NOT exercise a real Slack OAuth dance — that would require a live
  Slack workspace. Instead we stub `Req` via `Req.Test` plugs to assert
  the URL-construction and token-storage / decryption paths, and call
  `Contract.Integrations.Slack.complete_oauth/3` with a stubbed
  `:req_opts` so the HTTP call is intercepted in-process.
  """
  # NOT async — the suite mutates process-level SLACK_* env vars in
  # `setup`, and the controller test in test/contract_web/controllers/
  # mutates the same vars. Two concurrent tests would race.
  use Contract.DataCase, async: false

  import Contract.AccountsFixtures

  alias Contract.Context, as: Scope
  alias Contract.Integrations.Slack
  alias Contract.Integrations.SlackToken
  alias Contract.Repo

  setup do
    # Ensure the .env-derived Slack env vars are populated for the test
    # process (we want deterministic URLs regardless of host env).
    System.put_env("SLACK_CLIENT_ID", "test-client-id")
    System.put_env("SLACK_CLIENT_SECRET", "test-client-secret")
    System.put_env("SLACK_USER_AUTHORIZE_URL", "https://slack.com/oauth/v2_user/authorize")
    System.put_env("SLACK_USER_TOKEN_URL", "https://slack.com/api/oauth.v2.user.access")

    System.put_env(
      "SLACK_MCP_USER_SCOPES",
      "search:read.public,channels:history,users:read"
    )

    System.put_env("SLACK_MCP_WRITE_SCOPES", "chat:write,reactions:write")

    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, user: user, scope: scope}
  end

  describe "start_oauth/2" do
    test "builds an authorize URL with read-only scopes + CSRF state", %{scope: scope} do
      {:ok, %{authorize_url: url, state: state, scopes: scopes}} =
        Slack.start_oauth(scope, "https://app.example/auth/slack/callback")

      assert String.starts_with?(url, "https://slack.com/oauth/v2_user/authorize?")

      %URI{query: query_str} = URI.parse(url)
      params = URI.decode_query(query_str)

      assert params["client_id"] == "test-client-id"
      assert params["redirect_uri"] == "https://app.example/auth/slack/callback"
      assert params["state"] == state
      assert is_binary(state) and byte_size(state) >= 16

      assert params["user_scope"] =~ "search:read.public"
      assert params["user_scope"] =~ "channels:history"
      refute params["user_scope"] =~ "chat:write"

      assert "search:read.public" in scopes
    end

    test "includes write scopes when write?: true", %{scope: scope} do
      {:ok, %{authorize_url: url, scopes: scopes}} =
        Slack.start_oauth(scope, "https://app.example/auth/slack/callback", write?: true)

      %URI{query: query_str} = URI.parse(url)
      params = URI.decode_query(query_str)

      assert params["user_scope"] =~ "chat:write"
      assert params["user_scope"] =~ "reactions:write"
      assert params["user_scope"] =~ "search:read.public"

      assert "chat:write" in scopes
    end

    test "generates a new CSRF state on each call", %{scope: scope} do
      {:ok, %{state: s1}} = Slack.start_oauth(scope, "https://x/cb")
      {:ok, %{state: s2}} = Slack.start_oauth(scope, "https://x/cb")
      refute s1 == s2
    end
  end

  describe "complete_oauth/3" do
    test "exchanges code + stores an encrypted token row", %{scope: scope, user: user} do
      payload = %{
        "ok" => true,
        "authed_user" => %{
          "id" => "U01ABCDE",
          "access_token" => "xoxp-test-12345-secret",
          "scope" => "search:read.public,channels:history"
        },
        "team" => %{"id" => "T01TEAM", "name" => "Test Team"}
      }

      stub = req_stub_returning(payload)

      assert {:ok, %SlackToken{} = row} =
               Slack.complete_oauth(scope, "the-code", "https://app.example/cb", req_opts: stub)

      assert row.user_id == user.id
      assert row.slack_team_id == "T01TEAM"
      assert row.slack_user_id == "U01ABCDE"
      assert "search:read.public" in row.scopes
      assert "channels:history" in row.scopes

      # Token at rest is NOT plaintext.
      refute row.access_token == "xoxp-test-12345-secret"
      assert is_binary(row.access_token)
      assert byte_size(row.access_token) > 32
    end

    test "decrypts via token_for/1", %{scope: scope} do
      payload = %{
        "ok" => true,
        "authed_user" => %{
          "id" => "U01",
          "access_token" => "xoxp-roundtrip-abc",
          "scope" => "search:read.public"
        },
        "team" => %{"id" => "T01"}
      }

      {:ok, _} =
        Slack.complete_oauth(scope, "code", "https://x/cb", req_opts: req_stub_returning(payload))

      assert {:ok, "xoxp-roundtrip-abc"} = Slack.token_for(scope)
    end

    test "{:error, :not_connected} when no row exists", %{scope: scope} do
      assert {:error, :not_connected} = Slack.token_for(scope)
    end

    test "disconnect/1 removes the row", %{scope: scope, user: user} do
      payload = %{
        "ok" => true,
        "authed_user" => %{"id" => "U01", "access_token" => "xoxp-deleteme", "scope" => ""},
        "team" => %{"id" => "T01"}
      }

      {:ok, _} =
        Slack.complete_oauth(scope, "code", "https://x/cb", req_opts: req_stub_returning(payload))

      assert Repo.get_by(SlackToken, user_id: user.id)

      assert :ok = Slack.disconnect(scope)
      refute Repo.get_by(SlackToken, user_id: user.id)
      assert {:error, :not_connected} = Slack.token_for(scope)
    end

    test "re-connecting overwrites the existing row (no duplicates)", %{scope: scope, user: user} do
      payload1 = %{
        "ok" => true,
        "authed_user" => %{"id" => "U01", "access_token" => "xoxp-original", "scope" => ""},
        "team" => %{"id" => "T01TEAM"}
      }

      payload2 = %{
        "ok" => true,
        "authed_user" => %{"id" => "U01", "access_token" => "xoxp-refreshed", "scope" => ""},
        "team" => %{"id" => "T01TEAM"}
      }

      {:ok, _row1} =
        Slack.complete_oauth(scope, "c1", "https://x/cb", req_opts: req_stub_returning(payload1))

      {:ok, _row2} =
        Slack.complete_oauth(scope, "c2", "https://x/cb", req_opts: req_stub_returning(payload2))

      rows = Repo.all(SlackToken)
      assert length(Enum.filter(rows, &(&1.user_id == user.id))) == 1

      assert {:ok, "xoxp-refreshed"} = Slack.token_for(scope)
    end

    test "surfaces {:error, {:slack_error, ...}} when Slack returns ok=false", %{scope: scope} do
      payload = %{"ok" => false, "error" => "invalid_code"}

      assert {:error, {:slack_error, "invalid_code"}} =
               Slack.complete_oauth(scope, "bad-code", "https://x/cb",
                 req_opts: req_stub_returning(payload)
               )
    end

    test "surfaces {:error, {:malformed_response, _}} when payload missing access_token", %{
      scope: scope
    } do
      payload = %{"ok" => true, "team" => %{"id" => "T01"}}

      assert {:error, {:malformed_response, _}} =
               Slack.complete_oauth(scope, "code", "https://x/cb",
                 req_opts: req_stub_returning(payload)
               )
    end
  end

  describe "connection_info/1" do
    test "returns the row when connected", %{scope: scope} do
      payload = %{
        "ok" => true,
        "authed_user" => %{"id" => "U01", "access_token" => "xoxp-x", "scope" => "users:read"},
        "team" => %{"id" => "T01"}
      }

      {:ok, _} =
        Slack.complete_oauth(scope, "c", "https://x/cb", req_opts: req_stub_returning(payload))

      assert {:ok, %SlackToken{slack_team_id: "T01", scopes: ["users:read"]}} =
               Slack.connection_info(scope)
    end

    test "{:error, :not_connected} otherwise", %{scope: scope} do
      assert {:error, :not_connected} = Slack.connection_info(scope)
    end
  end

  describe "read_scopes/0 + write_scopes/0" do
    test "parses comma-separated env into a clean list" do
      assert "search:read.public" in Slack.read_scopes()
      assert "chat:write" in Slack.write_scopes()
    end
  end

  describe "OpenAI wire-through" do
    test "Contract.IO.OpenAI.slack_mcp_tool/1 returns a tool map for a connected scope",
         %{scope: scope} do
      payload = %{
        "ok" => true,
        "authed_user" => %{"id" => "U01", "access_token" => "xoxp-wired", "scope" => ""},
        "team" => %{"id" => "T01"}
      }

      {:ok, _} =
        Slack.complete_oauth(scope, "code", "https://x/cb", req_opts: req_stub_returning(payload))

      System.put_env("SLACK_MCP_URL", "https://mcp.slack.com/mcp")

      assert %{
               type: "mcp",
               server_label: "slack",
               server_url: "https://mcp.slack.com/mcp",
               require_approval: %{always: %{tool_names: write_names}},
               headers: %{"Authorization" => auth_hdr}
             } = Contract.IO.OpenAI.slack_mcp_tool(scope)

      assert auth_hdr == "Bearer xoxp-wired"
      assert "slack_post_message" in write_names
    end

    test "returns nil when the scope has no token", %{scope: scope} do
      assert Contract.IO.OpenAI.slack_mcp_tool(scope) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Returns `:req_opts` that, when merged into the Req call inside
  # `complete_oauth/3`, makes Req return `payload` as the JSON body of a
  # 200 response without leaving the test process. We use Req's `:adapter`
  # hook with a fun that bypasses the network entirely.
  defp req_stub_returning(payload) do
    [
      adapter: fn req ->
        {req, %Req.Response{status: 200, body: payload}}
      end
    ]
  end
end
