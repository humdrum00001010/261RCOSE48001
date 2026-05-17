defmodule ContractWeb.DashboardLiveTest do
  @moduledoc """
  DashboardLive test surface — re-baselined for v0.5/design-v31.

  The dashboard is now a Google-Docs-style document library
  (DESIGN.md §4): document grid only, no metric cards, no recent
  activity feed, no left sidebar. Contract upload is a popover
  anchored under the secondary action button, not a modal.

  Anti-regression tests below pin the binding feedback from
  feedback-mature-visual-language + feedback-review-adds-tests:

    * no `다음 질문` text on document cards (banned per DESIGN.md §7)
    * no metric-count substring like `최근 7일`
    * no `계약서 업로드` link in the global navbar
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "dashboard chrome (DESIGN.md §4)" do
    setup :register_and_log_in_user

    test "renders top-row title and the two action buttons", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # H1 + the two action buttons live in the dashboard content header.
      assert html =~ "최근 문서"
      assert html =~ "새 문서"
      assert html =~ "계약서 업로드"
      assert html =~ ~s(data-role="dashboard-new-document")
      assert html =~ ~s(data-role="dashboard-upload-trigger")
    end

    test "renders tabs row: 모든 문서 (active) / 즐겨찾기", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "모든 문서"
      assert html =~ "즐겨찾기"
      assert html =~ ~s(role="tablist")
      # Active tab must announce itself via aria-selected="true".
      assert html =~ ~s(aria-selected="true")
    end

    test "renders the empty state when the owner has no documents", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="documents-empty")
      # Action buttons + tabs are still visible in the empty state.
      assert html =~ "새 문서"
      assert html =~ "계약서 업로드"
      assert html =~ "모든 문서"
      # And NO document-grid cards.
      refute html =~ ~s(data-role="document-card")
    end

    test "renders one card per recent document", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "용역계약서 초안"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="document-grid")
      assert html =~ ~s(data-role="document-card")
      assert html =~ "용역계약서 초안"
      # 수정일 label appears on each card.
      assert html =~ "수정일"
    end
  end

  describe "upload popover (NOT a modal)" do
    setup :register_and_log_in_user

    test "starts closed; toggle_upload_menu opens it; click-away closes it", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      # Popover starts closed.
      refute html =~ ~s(data-role="upload-menu")

      # Toggling flips :upload_menu_open? and renders the popover content.
      html_open = lv |> element(~s([data-role="dashboard-upload-trigger"])) |> render_click()
      assert html_open =~ ~s(data-role="upload-menu")
      assert html_open =~ "파일에서 가져오기"
      assert html_open =~ "기존 계약서 파일을 StudioLive로 가져옵니다."
      assert html_open =~ "PDF, DOCX, HWP 지원"

      # click-outside closes via phx-click-away="close_upload_menu".
      html_closed = render_click(lv, "close_upload_menu", %{})
      refute html_closed =~ ~s(data-role="upload-menu")
    end

    test "popover wires a real <input type=file> via live_file_input", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html = lv |> element(~s([data-role="dashboard-upload-trigger"])) |> render_click()

      assert html =~ ~s(type="file")
      # accept attribute carries the four supported extensions
      assert html =~ ".pdf"
      assert html =~ ".docx"
      assert html =~ ".hwp"
    end
  end

  describe "new_document action" do
    setup :register_and_log_in_user

    test "creates an untyped owner-scoped doc and navigates to Studio", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element(~s([data-role="dashboard-new-document"])) |> render_click()

      [doc] = Documents.list_recent_for_scope(scope, 5)
      assert doc.owner_id == scope.user.id
      assert doc.type_key == nil
      assert_redirect(lv, ~p"/documents/#{doc.id}")
    end
  end

  describe "anti-regression (binding feedback + DESIGN.md §7)" do
    setup :register_and_log_in_user

    test "document cards never contain `다음 질문`", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "Engagement letter"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "다음 질문"
    end

    test "dashboard has no metric-count tiles (no `최근 7일`)", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "stat-bait"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "최근 7일"
      refute html =~ "발행됨"
      # The old "Active matters" stat row never returns.
      refute html =~ "Active matters"
    end

    test "dashboard has no recent activity feed", %{conn: conn, scope: scope} do
      {:ok, doc} = Documents.create(scope, %{title: "Activity bait"})

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: scope.user.id,
        result_revision: 1,
        message: "this message must NOT appear on the dashboard"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="recent-activity")
      refute html =~ "this message must NOT appear on the dashboard"
    end

    test "global navbar does NOT carry a `계약서 업로드` action", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # `계약서 업로드` must appear EXACTLY inside the dashboard content
      # header — never in the navbar. Count substring occurrences and
      # assert the number matches "trigger button + popover header label
      # (when open)"; when the menu is closed (default), the only
      # occurrence is the secondary button label itself.
      occurrences =
        html
        |> String.split("계약서 업로드")
        |> length()
        |> Kernel.-(1)

      # Closed-menu render: 1 in the secondary button + 1 in the
      # aria-label on the popover (which is rendered only when open).
      # We assert <= 2 to cover both "menu starts closed" (1) and any
      # future change where the trigger label also appears in aria
      # attributes. The key constraint is that the navbar contributes 0.
      assert occurrences >= 1
      assert occurrences <= 2

      # And explicitly assert the navbar (above the main content) does
      # not link to anything labelled `계약서 업로드`. The dashboard's
      # secondary button is a <button>, not an <a href>, so an anchor
      # with that label would have to come from the navbar.
      refute html =~ ~r/<a[^>]*>\s*계약서 업로드/u
    end
  end
end
