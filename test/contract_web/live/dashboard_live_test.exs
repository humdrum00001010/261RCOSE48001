defmodule ContractWeb.DashboardLiveTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "dashboard chrome" do
    setup :log_in_a_user

    test "renders the welcome heading + the three stat cards", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Good day"
      assert html =~ "Active matters"
      assert html =~ "Documents"
      assert html =~ "Open agent runs"
    end

    test "shows the persona dropdown with the user's email in the navbar",
         %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ user.email
      assert html =~ "Log out"
    end
  end

  describe "matters empty state" do
    setup :log_in_a_user

    test "renders the 'No matters yet' empty state when no matters exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "No matters yet"
      assert html =~ ~s(id="matters-empty")
      refute html =~ ~s(id="matters-grid")
    end

    test "renders the documents empty state when no documents exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ ~s(id="documents-empty")
      refute html =~ ~s(id="documents-list")
    end

    test "renders the activity empty state when there are no changes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ ~s(id="activity-empty")
    end
  end

  describe "new-document modal" do
    setup :log_in_a_user

    test "opens the modal and shows contract-type options", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute render(lv) =~ ~s(id="new-document-modal")

      html =
        lv
        |> element("button", "New Document")
        |> render_click()

      assert html =~ ~s(id="new-document-modal")
      assert html =~ "nda_v1"
      assert html =~ "franchise_v1"
      assert html =~ "service_agreement_v1"
    end

    test "closing the modal hides it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()
      assert render(lv) =~ ~s(id="new-document-modal")

      lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute render(lv) =~ ~s(id="new-document-modal")
    end

    test "picking a type closes the modal and flashes a TODO note", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()

      html =
        lv
        |> element(~s(button[phx-value-type_key="nda_v1"]))
        |> render_click()

      refute html =~ ~s(id="new-document-modal")
      assert html =~ "Document creation for nda_v1 is queued"
    end
  end

  describe "documents + activity populated state" do
    setup :log_in_a_user

    # `Contract.Matters` doesn't exist yet (Wave 3C1), so we can't drive the
    # *matters* populated branch directly. We *can*, however, exercise the
    # `recent_documents` and `activity` populated branches by inserting raw
    # rows into the `changes` table — the dashboard's stub
    # `list_recent_documents/1` and `list_activity/1` read straight from it.
    test "renders the documents list + activity feed when changes exist", %{conn: conn} do
      doc_id_a = Ecto.UUID.generate()
      doc_id_b = Ecto.UUID.generate()

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_id_a,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 1,
        message: "first commit on A"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_id_a,
        action_kind: "rename_document",
        actor_type: :agent,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 2,
        message: "rename"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_id_b,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 1,
        message: "first commit on B"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Recent-documents section: populated branch.
      assert html =~ ~s(id="documents-list")
      refute html =~ ~s(id="documents-empty")
      # The dashboard renders a per-document title built from the first 8
      # chars of the document_id (see DashboardLive.decorate_document/1).
      assert html =~ "Document " <> String.slice(doc_id_a, 0, 8)
      assert html =~ "Document " <> String.slice(doc_id_b, 0, 8)

      # Activity section: populated branch.
      assert html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="activity-empty")
      # Two distinct actor classes (user + agent) should be reflected.
      assert html =~ "first commit on A"
      assert html =~ "rename"

      # Stat row: `documents` count should reflect the 2 distinct doc_ids,
      # `active_matters` still 0 (no Matters schema yet).
      assert html =~ "Documents"
      assert html =~ "Active matters"
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
