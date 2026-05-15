defmodule ContractWeb.UserLive.SettingsHubTest do
  @moduledoc """
  Tests the `/settings` hub LiveView and the sibling
  `/settings/api-tokens` stub. Wave 3C0-B/3.

  Sub-pages still owned by gen.auth (the existing `/users/settings`
  account form) are NOT touched here — those live in
  `settings_test.exs`. We only verify that the hub links to the
  account page and that the sidebar's "Coming soon" items are
  rendered as disabled placeholders.
  """
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  describe "auth gate" do
    test "/settings redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "/settings/api-tokens redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/settings/api-tokens")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "/settings hub" do
    setup :log_in_a_user

    test "renders the welcome panel with the user's email", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Your account"
      assert html =~ user.email
      assert html =~ ~s(id="settings-hub-welcome")
    end

    test "renders the sidebar with 6 category items (3 active + 3 'Soon')",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ ~s(id="settings-sidebar")
      # The three active items (Account, API tokens, Integrations)
      assert html =~ "Account"
      assert html =~ "API tokens"
      assert html =~ "Integrations"
      # The three disabled placeholders
      assert html =~ "Appearance"
      assert html =~ "Workspace"
      assert html =~ "Notifications"
      # Disabled markers
      assert html =~ "aria-disabled=\"true\""
      assert html =~ "Soon"
    end

    test "renders the 2x2 quick-link grid on the welcome panel", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ ~s(id="settings-quick-grid")
      # Two enabled quick-cards (Account + API tokens) navigate links.
      assert html =~ ~s(href="/users/settings")
      assert html =~ ~s(href="/settings/api-tokens")
    end

    test "sidebar 'Account' link points to /users/settings", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      # The sidebar nav contains an <a navigate="/users/settings"> with
      # the label "Account". We verify the link is present and resolves.
      assert lv
             |> element(~s(#settings-sidebar a[href="/users/settings"]))
             |> has_element?()
    end
  end

  describe "/settings/api-tokens" do
    setup :log_in_a_user

    test "renders the empty state with a Generate button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/api-tokens")

      assert html =~ ~s(id="api-tokens-page")
      assert html =~ ~s(id="api-tokens-empty")
      assert html =~ "No API tokens yet"
      assert html =~ "Generate token"
    end

    test "highlights 'API tokens' in the shared sidebar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/api-tokens")

      # The shared sidebar renders the same items; on this page the
      # API-tokens entry carries aria-current="page".
      assert html =~ ~s(aria-current="page")
      assert html =~ "API tokens"
    end

    test "clicking 'Generate token' opens the modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/api-tokens")

      refute render(lv) =~ ~s(id="generate-token-modal")

      html =
        lv
        |> element("#generate-token-button")
        |> render_click()

      assert html =~ ~s(id="generate-token-modal")
      assert html =~ "Generate API token"
      assert html =~ "Purpose"
      assert html =~ "TTL (hours)"
    end

    test "submitting the modal form flashes 'Generated:' and closes the modal",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/api-tokens")

      lv |> element("#generate-token-button") |> render_click()

      # `matter_id` select is intentionally disabled until Wave-X persistence
      # lands and we can populate it from Contract.Matters; LiveViewTest
      # refuses to submit disabled inputs, so we only fill the enabled fields.
      html =
        lv
        |> form("#generate-token-form",
          token: %{purpose: "mcp-cli", ttl_hours: "24"}
        )
        |> render_submit()

      refute html =~ ~s(id="generate-token-modal")
      assert html =~ "Generated:"
    end

    test "closing the modal hides it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/api-tokens")

      lv |> element("#generate-token-button") |> render_click()
      assert render(lv) =~ ~s(id="generate-token-modal")

      lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute render(lv) =~ ~s(id="generate-token-modal")
    end
  end

  describe "unrouted sub-pages" do
    setup :log_in_a_user

    test "/settings/appearance does NOT route (placeholder, not yet wired)",
         %{conn: _conn} do
      # The route isn't defined yet — Phoenix.Router raises NoRouteError
      # at request time. LiveViewTest surfaces this as a function-clause
      # error from the verified-routes sigil being unavailable, so we
      # call `Phoenix.Router.route_info/4` directly.
      assert Phoenix.Router.route_info(
               ContractWeb.Router,
               "GET",
               "/settings/appearance",
               "localhost"
             ) == :error
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
