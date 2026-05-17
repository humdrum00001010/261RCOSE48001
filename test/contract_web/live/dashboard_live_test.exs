defmodule ContractWeb.DashboardLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Documents

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "dashboard" do
    setup :register_and_log_in_user

    test "renders document-first chrome without Matter language", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Good day"
      assert html =~ user.email
      assert html =~ "New Document"
      assert html =~ ~s(id="recent-documents")
      assert html =~ ~s(id="documents-empty")
      refute html =~ "Matter"
      refute html =~ "Active matters"
    end

    test "creates an untyped owner-scoped document and navigates to /documents/:id", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element("button", "New Document") |> render_click()

      lv
      |> form(~s(form[data-role="new-document-form"]), %{title: "Quick draft"})
      |> render_submit()

      [doc] = Documents.list_recent_for_scope(scope, 5)
      assert doc.title == "Quick draft"
      assert doc.owner_id == scope.user.id
      assert doc.type_key == nil
      assert_redirect(lv, ~p"/documents/#{doc.id}")
    end

    test "renders recent documents and activity", %{conn: conn, scope: scope, user: user} do
      {:ok, doc} = Documents.create(scope, %{title: "Engagement letter", type_key: "nda_v1"})

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: user.id,
        result_revision: 1,
        message: "tightened section 3"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="documents-list")
      assert html =~ "Engagement letter"
      assert html =~ ~p"/documents/#{doc.id}"
      assert html =~ ~s(id="activity-feed")
      assert html =~ "tightened section 3"
    end

    test "activity feed only renders changes for the current user documents", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other_user = user_fixture()
      other_scope = Context.for_user(other_user)

      {:ok, own_doc} = Documents.create(scope, %{title: "Own activity doc", type_key: "nda_v1"})

      {:ok, other_doc} =
        Documents.create(other_scope, %{title: "Foreign activity doc", type_key: "nda_v1"})

      Contract.Repo.insert!(%Contract.Change{
        document_id: own_doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: user.id,
        result_revision: 1,
        message: "visible owner change"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: other_doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: other_user.id,
        result_revision: 1,
        message: "foreign owner change"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "visible owner change"
      refute html =~ "foreign owner change"
    end
  end
end
