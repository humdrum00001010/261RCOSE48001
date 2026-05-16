defmodule ContractWeb.ThemeToggleTest do
  @moduledoc """
  Wallaby smoke for the theme toggle on the landing page. The Wave 0.5
  rename of the daisyUI theme values (`light|dark` → `studio|studio-dark`)
  left the JS handler out-of-sync; Wave 3C0-E reworked the handler to
  use a delegated click listener that works on dead views too. This
  test exists to prevent a future regression.

  Asserts:
    1. Click the dark-theme button → `<html data-theme="studio-dark">`.
    2. Click the light-theme button → `<html data-theme="studio">`.
    3. Reload after picking dark → the preference persists in
       localStorage and the attribute is re-applied on boot.

  Implementation note: Wallaby's `assert_has(Query.css("html[...]"))`
  cannot match the document root element (WebDriver's `findElements`
  searches descendants, and `<html>` IS the root, so it returns 0
  matches even when the attribute is correctly set). We therefore
  read `document.documentElement.dataset.theme` via `execute_script`
  and assert on the returned value. Playwright (which uses CDP) does
  not have this limitation — only Wallaby's WebDriver path does.

  Tagged `:browser` so it stays out of the default `mix test` run.
  """

  use ContractWeb.FeatureCase, async: false

  @moduletag :browser

  feature "data-phx-theme lives on a <button> element (not a wrapper div)",
          %{session: session} do
    # Regression guard: the Wave 3D navbar-alignment refactor restructured
    # the theme_toggle markup (dropped `.card`, switched segment buttons
    # from `flex p-2` to `inline-flex … h-full`). If a future refactor
    # moves `data-phx-theme` off the clickable <button> onto the wrapper
    # <div>, the delegated `closest("[data-phx-theme]")` handler in
    # root.html.heex would still fire on direct wrapper clicks but real
    # users hitting the icon would silently no-op (the wrapper isn't
    # interactable and the icon would lose its data ancestor chain in a
    # different layout). Asserting tagName=BUTTON on EVERY data-phx-theme
    # element pins the contract: clickable element owns the attribute.
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> assert_data_phx_theme_on_buttons(["system", "studio", "studio-dark"])
  end

  feature "dark button switches to data-theme=studio-dark", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> assert_theme("studio-dark")
  end

  feature "light button switches to data-theme=studio", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> assert_theme("studio-dark")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio"])))
    |> assert_theme("studio")
  end

  feature "theme preference persists across reload", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> assert_theme("studio-dark")
    |> Wallaby.Browser.visit("/")
    |> assert_theme("studio-dark")
  end

  # Read `<html data-theme>` via execute_script and assert it equals
  # `expected`. Polls up to 2s — the toggle handler runs in a JS frame
  # after the click, and Wallaby's `click/2` returns before the handler
  # has necessarily completed.
  defp assert_theme(session, expected) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_assert_theme(session, expected, deadline)
  end

  defp do_assert_theme(session, expected, deadline) do
    actual = read_theme(session)

    cond do
      actual == expected ->
        session

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk(
          "Expected <html data-theme=#{inspect(expected)}>, got #{inspect(actual)}"
        )

      true ->
        Process.sleep(50)
        do_assert_theme(session, expected, deadline)
    end
  end

  defp read_theme(session) do
    parent = self()
    ref = make_ref()

    Wallaby.Browser.execute_script(
      session,
      "return document.documentElement.getAttribute('data-theme');",
      [],
      fn value -> send(parent, {ref, value}) end
    )

    receive do
      {^ref, value} -> value
    after
      2_000 -> nil
    end
  end

  # Assert each expected `data-phx-theme` value resolves to (a) exactly one
  # element on the page and (b) that element is a <button>. The wrapper
  # <div> around the segment buttons must NOT also carry the attribute —
  # `querySelectorAll('[data-phx-theme=...]').length === 1` enforces both.
  defp assert_data_phx_theme_on_buttons(session, themes) do
    Enum.each(themes, fn theme ->
      parent = self()
      ref = make_ref()

      Wallaby.Browser.execute_script(
        session,
        ~s"""
        var nodes = document.querySelectorAll('[data-phx-theme="#{theme}"]');
        return [nodes.length, nodes[0] ? nodes[0].tagName : null];
        """,
        [],
        fn [count, tag] -> send(parent, {ref, count, tag}) end
      )

      {count, tag} =
        receive do
          {^ref, c, t} -> {c, t}
        after
          2_000 -> {0, nil}
        end

      ExUnit.Assertions.assert(
        count == 1,
        "Expected exactly one [data-phx-theme=#{inspect(theme)}], got #{count}"
      )

      ExUnit.Assertions.assert(
        tag == "BUTTON",
        "Expected [data-phx-theme=#{inspect(theme)}] on a <button>, got <#{tag}>"
      )
    end)

    session
  end
end
