defmodule ContractWeb.Components.CommandPaletteTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias ContractWeb.Components.CommandPalette

  # --- Persona-perm fixtures (mirror Contract.PersonaFactory) ---------

  defp lawyer_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp paralegal_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a
    }

  defp agent_supervised_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke agent_run)a
    }

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp admin_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms:
          ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }

  describe "available_commands/1 — persona perms matrix" do
    setup do
      %{user: user_fixture()}
    end

    test "lawyer sees export, revoke, set-type (Studio matter present)", %{user: user} do
      scope = %Context{lawyer_scope(user) | matter: "matter-abc"}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      assert :doc_request_export in ids
      assert :doc_revoke_last in ids
      assert :doc_set_type in ids
      assert :nav_dashboard in ids
      assert :search_law in ids
    end

    test "paralegal sees revoke + set-type but NOT request export", %{user: user} do
      scope = %Context{paralegal_scope(user) | matter: "matter-abc"}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      assert :doc_revoke_last in ids
      assert :doc_set_type in ids
      refute :doc_request_export in ids
    end

    test "agent_supervised sees revoke but NOT export or set-type", %{user: user} do
      scope = %Context{agent_supervised_scope(user) | matter: "matter-abc"}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      assert :doc_revoke_last in ids
      refute :doc_request_export in ids
      refute :doc_set_type in ids
    end

    test "viewer sees only navigation/search/help — no Documents at all", %{user: user} do
      scope = %Context{viewer_scope(user) | matter: "matter-abc"}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      assert :nav_dashboard in ids
      assert :search_law in ids
      assert :help_shortcuts in ids
    end

    test "admin sees the full Documents group", %{user: user} do
      scope = %Context{admin_scope(user) | matter: "matter-abc"}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      assert :doc_request_export in ids
      assert :doc_revoke_last in ids
      assert :doc_set_type in ids
    end

    test "Documents commands hide when scope.matter is nil even for a lawyer",
         %{user: user} do
      scope = %Context{lawyer_scope(user) | matter: nil}
      ids = scope |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      # Navigation/search/help still present.
      assert :nav_dashboard in ids
    end

    test "nil scope yields navigation+search+help only (no Documents group)",
         %{user: _user} do
      ids = nil |> CommandPalette.available_commands() |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      assert :nav_dashboard in ids
      assert :search_law in ids
    end
  end

  describe "filter_commands/2 — fuzzy subsequence matching" do
    setup %{} do
      user = user_fixture()
      scope = %Context{lawyer_scope(user) | matter: "matter-abc"}
      %{commands: CommandPalette.available_commands(scope)}
    end

    test "empty query returns the full catalog in order", %{commands: commands} do
      assert CommandPalette.filter_commands(commands, "") == commands
    end

    test "'go to' filters down to the navigation commands", %{commands: commands} do
      labels =
        commands
        |> CommandPalette.filter_commands("go to")
        |> Enum.map(& &1.label)

      assert "Go to dashboard" in labels
      assert "Go to landing" in labels
      refute "Search Korean law…" in labels
    end

    test "case-insensitive substring fuzzy match", %{commands: commands} do
      labels =
        commands
        |> CommandPalette.filter_commands("DASH")
        |> Enum.map(& &1.label)

      assert "Go to dashboard" in labels
    end

    test "nonsense query yields empty list", %{commands: commands} do
      assert CommandPalette.filter_commands(commands, "zzzqqq") == []
    end

    test "score/2 returns nil for non-subsequence and a positive number for match" do
      assert CommandPalette.score("Go to dashboard", "zzz") == nil

      score = CommandPalette.score("Go to dashboard", "got")
      assert is_float(score)
      assert score > 0
    end
  end

  describe "render_component/2 — closed-by-default + persona filtering" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "renders the trigger button (closed by default)", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user)
        )

      assert html =~ ~s(data-role="palette-trigger")
      assert html =~ "⌘K"
      # No modal-open container when closed.
      refute html =~ ~s(data-role="palette-box")
    end

    # Wave 4 bugfix #6 — Playwright Scenario 6 selector contract.
    # The root container is permanently mounted and exposes a hook +
    # `data-open` for state tracking; the modal box (with the visible
    # palette UI) is only rendered when `@open?` flips. Playwright
    # presses Cmd/Ctrl+K then waits for `[data-role="command-palette"]`
    # to be visible — so the data-role must land on a sized element,
    # which only exists in the open state. The root keeps its own
    # `data-role="command-palette-root"` so closed-state tests can
    # still locate the mounted hook.
    test "closed palette renders root with data-role=\"command-palette-root\" + data-open=\"false\"",
         %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user)
        )

      assert html =~ ~s(data-role="command-palette-root")
      assert html =~ ~s(data-open="false")
      # Modal box (with the trailing-quote variant of the data-role)
      # is NOT in the DOM when closed.
      refute html =~ ~s(data-role="command-palette" )
      refute html =~ ~s(data-role="command-palette">)
    end

    test "open palette renders modal box with data-role=\"command-palette\"",
         %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true
        )

      # Both data-roles are present when open:
      #   - root carries `command-palette-root` + `data-open="true"`
      #   - modal-box carries `command-palette` (sized → Playwright-visible)
      assert html =~ ~s(data-role="command-palette-root")
      assert html =~ ~s(data-open="true")
      # Modal-box selector — close-quote then space or `>`.
      assert html =~ ~s(data-role="command-palette" ) or
               html =~ ~s(data-role="command-palette">)
    end

    test "with initial_open?, renders the modal and the input", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true
        )

      assert html =~ ~s(data-role="palette-box")
      assert html =~ ~s(data-role="palette-input")
      assert html =~ "Type a command"
      assert html =~ "Navigation"
    end

    test "open palette for a lawyer with matter shows Request export…", %{user: user} do
      scope = %Context{lawyer_scope(user) | matter: "matter-abc"}

      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: scope,
          initial_open?: true
        )

      assert html =~ "Request export"
      assert html =~ "Documents"
    end

    test "open palette for a viewer hides the Documents group entirely", %{user: user} do
      scope = %Context{viewer_scope(user) | matter: "matter-abc"}

      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: scope,
          initial_open?: true
        )

      refute html =~ "Request export"
      refute html =~ "Revoke last change"
      refute html =~ "Set contract type"
      # Documents group header should also not appear since no commands match.
      refute html =~ ~s(>Documents<)
      # Help group still present.
      assert html =~ "Keyboard shortcuts"
    end

    test "initial_query='dashboard' narrows the rendered list", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true,
          initial_query: "dashboard"
        )

      assert html =~ "Go to dashboard"
      refute html =~ "Search Korean law"
    end

    test "info mode renders the shortcuts cheatsheet", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true,
          initial_mode: :info
        )

      # The info_target defaults to nil; we render the heading even so but
      # the body falls back to empty when target is unset. Set explicit
      # target via assigns is not currently supported — assert the panel
      # chrome is present.
      assert html =~ "Back"
    end
  end

  describe "end-to-end via /dashboard — toggle / typing / Esc" do
    setup :log_in_a_user

    test "the palette mounts on /dashboard and starts closed", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      # Trigger button is rendered, modal-box is NOT.
      assert html =~ ~s(data-role="palette-trigger")
      refute render(lv) =~ ~s(data-role="palette-box")
    end

    test "clicking the trigger opens the modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv
        |> element(~s([data-role="palette-trigger"]))
        |> render_click()

      assert html =~ ~s(data-role="palette-box")
      assert html =~ "Type a command"
    end

    test "after opening, typing 'go to' filters the list down to navigation",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv
      |> element(~s([data-role="palette-trigger"]))
      |> render_click()

      html =
        lv
        |> form("form[phx-change='query']", %{"value" => "go to"})
        |> render_change()

      assert html =~ "Go to dashboard"
      assert html =~ "Go to landing"
      refute html =~ "Search Korean law"
    end

    test "Esc closes the open palette", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv
      |> element(~s([data-role="palette-trigger"]))
      |> render_click()

      assert render(lv) =~ ~s(data-role="palette-box")

      # The Esc bridge element is `phx-window-keydown="key" phx-key="Escape"`
      # targeting the component — fire a keydown on it.
      html =
        lv
        |> element("#cmd-k-palette-keys-escape")
        |> render_keydown(%{"key" => "Escape"})

      refute html =~ ~s(data-role="palette-box")
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
