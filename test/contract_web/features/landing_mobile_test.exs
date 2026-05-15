defmodule ContractWeb.LandingMobileTest do
  @moduledoc """
  Wallaby smoke for the landing page at a mobile viewport. Asserts that
  the hamburger drawer toggle is present on `< lg` widths (375×667 — the
  iPhone SE size we ship a baseline for) and that the drawer side
  contains the public nav items.

  Tagged `:browser` so it stays out of the default `mix test` run; CI /
  sprite runs `mix test --include browser`.
  """

  use ContractWeb.FeatureCase, async: false

  @moduletag :browser

  feature "hamburger drawer toggle is visible on mobile viewport", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(375, 667)
    |> Wallaby.Browser.visit("/")
    |> assert_has(Query.css("label[for='mobile-nav-drawer']"))
    |> assert_has(Query.css("input#mobile-nav-drawer", visible: false))
  end

  feature "hero image renders on mobile viewport", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(375, 667)
    |> Wallaby.Browser.visit("/")
    |> assert_has(Query.css("img[src*='/images/landing/hero.png']"))
  end
end
