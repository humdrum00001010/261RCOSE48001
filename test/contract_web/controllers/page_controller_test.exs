defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase

  test "GET / renders the landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Contract Studio"
    assert body =~ "Drafting that asks before it edits."
    assert body =~ "Grill-me agent"
  end

  test "GET / embeds the generated hero image", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/images/landing/hero.png"
  end

  test "GET / embeds the three generated feature illustrations", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/images/landing/feature-grill-me.png"
    assert body =~ "/images/landing/feature-citation.png"
    assert body =~ "/images/landing/feature-conversion.png"
  end

  test "GET / exposes the hamburger drawer toggle on mobile", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # The drawer toggle is the input + label pair used by DaisyUI's drawer.
    assert body =~ ~s(id="mobile-nav-drawer")
    assert body =~ ~s(for="mobile-nav-drawer")
  end
end
