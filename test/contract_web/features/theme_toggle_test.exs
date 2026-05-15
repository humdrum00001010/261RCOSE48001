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
end
