defmodule ContractWeb.LayoutsTopNavTest do
  @moduledoc """
  Heex render assertions for `ContractWeb.Layouts.top_nav/1` — guards against
  baseline-wobble regressions in the navbar row.

  The user-visible symptom this test prevents: nav items rendering at slightly
  different vertical centers because direct flex children disagree on height
  (e.g. a btn-sm at h-8 next to a plain `<a>` text link with line-height
  ~20px next to a custom theme-toggle pill with border-2 + p-2). The fix
  pins both the row (`h-14 items-center`) and every direct child
  (`inline-flex items-center h-9`) so the row centers them on a single axis.

  Tests are pure render-string assertions — no LiveView, no Wallaby,
  fast and deterministic.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Layouts

  defp scope(user \\ %{id: 1, email: "lawyer@example.com"}) do
    %{user: user}
  end

  describe "top_nav/1 row container" do
    test "anonymous: row has flex + items-center + explicit h-14" do
      html = render_component(&Layouts.top_nav/1, current_scope: nil)

      # First descendant of <header> is the row <div>. Assert its classes
      # contain the alignment + height tokens — order-independent.
      assert html =~ "flex"
      assert html =~ "items-center"
      assert html =~ "h-14"
      # The row must NOT wrap — every item lives on one line at every viewport.
      assert html =~ "flex-nowrap"
    end

    test "signed-in: row has flex + items-center + explicit h-14" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      assert html =~ "flex"
      assert html =~ "items-center"
      assert html =~ "h-14"
      assert html =~ "flex-nowrap"
    end
  end

  describe "top_nav/1 direct children alignment" do
    test "signed-in: wordmark link is inline-flex items-center with h-9" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # The wordmark <a> wrapper carries the canonical alignment shape.
      # Match a snippet of its class list — order-tolerant.
      assert html =~ ~r/<a[^>]*class="[^"]*inline-flex[^"]*items-center[^"]*h-9/
    end

    test "signed-in: nav links cluster carries items-center + h-9" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # The lg-visible nav <nav> wrapper around Dashboard/Studio.
      assert html =~ ~r/<nav[^>]*class="[^"]*items-center[^"]*h-9/
    end

    test "signed-in: persona dropdown trigger pinned to h-9 (matches row baseline)" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # The dropdown trigger is the daisyUI btn-sm with our pinned height.
      assert html =~ "h-9 min-h-9"
    end

    test "anonymous: Register CTA is pinned to h-9 (matches row baseline)" do
      html = render_component(&Layouts.top_nav/1, current_scope: nil)

      # The primary Register button must share the row height.
      assert html =~ "btn btn-primary"
      assert html =~ "h-9 min-h-9"
    end
  end

  describe "top_nav/1 — Cmd+K trigger anchored as a navbar item" do
    test "signed-in: Cmd+K trigger renders as a child of the navbar (not a viewport floater)" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # Trigger is present.
      assert html =~ ~s(data-role="palette-trigger")
      assert html =~ "⌘K"

      # And it lives INSIDE the <header> — i.e. it's a navbar child, not
      # a sibling that escapes to the viewport. We do a structural assert
      # by matching a <header> ... <button data-role="palette-trigger">
      # ... </header> window without an intervening </header>.
      assert Regex.match?(
               ~r/<header[^>]*>(?:(?!<\/header>).)*data-role="palette-trigger"(?:(?!<\/header>).)*<\/header>/s,
               html
             )
    end

    test "signed-in: Cmd+K trigger carries inline-flex items-center h-9 (matches sibling baseline)" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # The trigger button's attributes can render in either order
      # (`class` before `data-role` or vice-versa). Match the open <button>
      # tag opaquely, then assert both the class tokens and the trigger
      # marker land on the same tag.
      assert html =~
               ~r/<button[^>]*\bclass="[^"]*\binline-flex\b[^"]*\bitems-center\b[^"]*\bh-9\b[^"]*"[^>]*data-role="palette-trigger"/

      # It must NOT carry viewport-fixed positioning classes.
      refute html =~ ~r/<button[^>]*\bfixed\b[^>]*data-role="palette-trigger"/
      refute html =~ ~r/<button[^>]*\bsticky\b[^>]*data-role="palette-trigger"/
    end

    test "signed-in: Cmd+K trigger is wired to toggle the palette LiveComponent" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())

      # `phx-click="toggle"` + `phx-target="#cmd-k-palette"` routes the
      # click to the palette LiveComponent's `handle_event("toggle", ...)`.
      assert html =~
               ~r/<button[^>]*phx-click="toggle"[^>]*data-role="palette-trigger"/

      assert html =~
               ~r/<button[^>]*phx-target="#cmd-k-palette"[^>]*data-role="palette-trigger"/
    end

    test "anonymous: Cmd+K trigger is NOT rendered (palette only mounts for signed-in scopes)" do
      html = render_component(&Layouts.top_nav/1, current_scope: nil)

      refute html =~ ~s(data-role="palette-trigger")
    end
  end

  describe "theme_toggle/1 — embedded in the navbar row" do
    test "outer pill has explicit h-9 + inline-flex items-center (matches row baseline)" do
      html = render_component(&Layouts.theme_toggle/1, %{})

      # The pill must NOT introduce its own height — h-9 keeps it aligned
      # with the other row items.
      assert html =~ "inline-flex"
      assert html =~ "items-center"
      assert html =~ "h-9"
      # Each segment button must center its icon (was `flex p-2` only,
      # which left the icon top-aligned on tall lines).
      assert html =~ ~r/<button[^>]*class="[^"]*inline-flex[^"]*items-center[^"]*justify-center/
    end
  end

  describe "mobile_nav/1 — drawer integrity" do
    test "drawer renders for signed-in scope (hamburger still wires up a working drawer)" do
      html = render_component(&Layouts.mobile_nav/1, current_scope: scope())

      # Smoke: the drawer aside is present + has the expected nav landmarks.
      assert html =~ "<aside"
      assert html =~ "Dashboard"
      assert html =~ "Studio"
      assert html =~ "Settings"
    end

    test "drawer renders for anonymous scope" do
      html = render_component(&Layouts.mobile_nav/1, current_scope: nil)

      assert html =~ "<aside"
      assert html =~ "Docs"
      assert html =~ "Changelog"
    end
  end
end
