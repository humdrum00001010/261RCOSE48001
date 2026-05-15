defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase

  test "GET / renders the landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Contract Studio"
    assert body =~ "Drafting that asks before it edits."
    assert body =~ "Grill-me agent"
  end
end
