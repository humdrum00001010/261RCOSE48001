defmodule ContractWeb.UserLive.IntegrationsTest do
  @moduledoc """
  Tests for the `/settings/integrations` LV (Wave 6).

  Covers:

    * Auth gate: anonymous users get redirected to log-in.
    * Empty state: authenticated user without a Slack token sees the
      "Slack 연결" affordance.
    * Connected state: authenticated user with a stored token row sees
      the disconnect form + team / scopes summary.
  """
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Integrations.Slack
  alias Contract.Integrations.SlackToken
  alias Contract.Repo

  describe "auth gate" do
    test "anonymous users redirect to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/settings/integrations")
      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/users/log-in"
    end
  end

  describe "authenticated, NOT connected" do
    setup :register_and_log_in_user

    test "renders 'Slack 연결' CTA with link to /auth/slack/start; hides disconnect",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/integrations")

      assert html =~ ~s(id="integrations-page")
      assert html =~ ~s(id="integration-slack")
      assert html =~ ~s(id="slack-connect-button")
      assert html =~ "Slack 연결"
      assert html =~ "연결 안 됨"
      assert html =~ ~s(href="/auth/slack/start")
      refute html =~ ~s(id="slack-disconnect-button")
    end
  end

  describe "authenticated, connected" do
    setup [:register_and_log_in_user, :insert_slack_token]

    test "renders disconnect form + connected badge + team id + scopes summary",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/integrations")

      assert html =~ ~s(id="slack-disconnect-button")
      assert html =~ "Slack 연결 해제"
      assert html =~ "T01TEAM"
      assert html =~ "연결됨"
      assert html =~ "search:read.public"
      assert html =~ "channels:history"
      assert html =~ ~s(action="/auth/slack/disconnect")
      assert html =~ ~s(method="post")
      refute html =~ ~s(id="slack-connect-button")
    end
  end

  defp insert_slack_token(%{user: user}) do
    ciphertext = Slack.encrypt("xoxp-integrations-test-token")

    {:ok, row} =
      %SlackToken{}
      |> SlackToken.changeset(%{
        user_id: user.id,
        slack_team_id: "T01TEAM",
        slack_user_id: "U01ABC",
        access_token: ciphertext,
        scopes: ["search:read.public", "channels:history"]
      })
      |> Repo.insert()

    %{slack_token: row}
  end
end
