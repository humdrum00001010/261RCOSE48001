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
    test "/settings and /settings/api-tokens redirect anonymous users to /users/log-in",
         %{conn: conn} do
      login_path = ~p"/users/log-in"

      for path <- [~p"/settings", ~p"/settings/api-tokens"] do
        assert {:error, redirect} = live(conn, path)
        assert {:redirect, %{to: ^login_path, flash: flash}} = redirect
        assert %{"error" => "You must log in to access this page."} = flash
      end
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
      assert html =~ "Documents"
      refute html =~ "Workspace"
      assert html =~ "Notifications"
      # Disabled markers
      assert html =~ "aria-disabled=\"true\""
      assert html =~ "Soon"
    end

    test "quick-grid + sidebar both expose the Account / API-tokens links",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/settings")

      assert html =~ ~s(id="settings-quick-grid")
      assert html =~ ~s(href="/users/settings")
      assert html =~ ~s(href="/settings/api-tokens")

      assert lv
             |> element(~s(#settings-sidebar a[href="/users/settings"]))
             |> has_element?()
    end
  end

  describe "/settings/api-tokens" do
    setup :log_in_a_user

    test "API tokens page renders empty state and the sidebar highlights it",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/api-tokens")

      assert html =~ ~s(id="api-tokens-page")
      assert html =~ ~s(id="api-tokens-empty")
      assert html =~ "No API tokens yet"
      assert html =~ "Generate token"
      # Sidebar highlights the current page.
      assert html =~ ~s(aria-current="page")
    end

    test "Generate token modal: opens on click, submits to generate, closes on cancel",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/api-tokens")
      refute render(lv) =~ ~s(id="generate-token-modal")

      open_html =
        lv
        |> element("#generate-token-button")
        |> render_click()

      assert open_html =~ ~s(id="generate-token-modal")
      assert open_html =~ "Generate API token"
      assert open_html =~ "Purpose"
      assert open_html =~ "TTL (hours)"

      # Submit → flashes "Generated:" and closes the modal.
      submit_html =
        lv
        |> form("#generate-token-form", token: %{purpose: "mcp-cli", ttl_hours: "24"})
        |> render_submit()

      refute submit_html =~ ~s(id="generate-token-modal")
      assert submit_html =~ "Generated:"

      # Reopen, then close via the X button.
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
