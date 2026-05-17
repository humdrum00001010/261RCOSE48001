defmodule ContractWeb.DashboardLiveDocumentFirstTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents

  setup :register_and_log_in_user

  test "creates an owner-scoped document and navigates document-first", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    lv |> element(~s(button[data-role="dashboard-new-document"])) |> render_click()

    [doc] = Documents.list_recent_for_scope(scope, 5)
    assert doc.owner_id == scope.user.id
    assert doc.type_key == nil
    assert_redirect(lv, ~p"/documents/#{doc.id}")
  end
end
