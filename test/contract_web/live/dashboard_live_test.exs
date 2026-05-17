defmodule ContractWeb.DashboardLiveTest do
  @moduledoc """
  DashboardLive test surface — re-baselined for v0.5/design-v31 +
  2026-05-17 owner directive.

  The dashboard is a Google-Docs-style document library
  (DESIGN.md §4): hairline table only, no metric cards, no recent
  activity feed, no left sidebar. The `새 문서` button does NOT create
  a document or open a modal — it navigates the user to `/studio`,
  where Canvas.Empty hosts upload + blank + recent + agent-discussion
  affordances per SPEC.md §4.2 + §4.4.

  Per owner clarification (2026-05-17): documents render as a TABLE
  with per-row hover, focus, and click states — not as cards.

  Anti-regression tests below pin:

    * no `다음 질문` text on document rows (banned per DESIGN.md §7)
    * no metric-count substring like `최근 7일`
    * no `계약서 업로드` anywhere on the dashboard surface (the upload
      affordance now lives entirely inside /studio)
    * no card-namespace markup (`document-card-v31` is replaced by
      `document-table`)
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

    test "renders top-row title and the new-document button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # H1 + the single primary action button live in the dashboard
      # content header. No `계약서 업로드` button — that moved to /studio.
      # Heading is `모든 문서` (the dashboard surfaces the full library,
      # not a "recent N" slice — 2026-05-17 owner directive).
      assert html =~ "모든 문서"
      assert html =~ "새 문서"
      assert html =~ ~s(data-role="dashboard-new-document")
      refute html =~ ~s(data-role="dashboard-upload-trigger")
      # And the old `최근 문서` heading must not return.
      refute html =~ ~s(<h1 class="dashboard-v31__title">최근 문서)
    end

    test "renders tabs row: 모든 문서 (active) / 즐겨찾기", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "모든 문서"
      assert html =~ "즐겨찾기"
      assert html =~ ~s(role="tablist")
      # Active tab must announce itself via aria-selected="true".
      assert html =~ ~s(aria-selected="true")
    end

    test "renders the empty state row when the owner has no documents", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Empty state is a single muted row inside the table — not a
      # detached empty card.
      assert html =~ ~s(id="documents-empty")
      assert html =~ ~s(data-role="dashboard-documents-empty")
      assert html =~ ~s(class="document-table")
      assert html =~ "아직 문서가 없습니다."
      # Primary action + tabs are still visible in the empty state.
      assert html =~ "새 문서"
      assert html =~ "모든 문서"
      # And NO document rows.
      refute html =~ ~s(data-role="document-row")
      # And no dead card-namespace markup.
      refute html =~ "document-card-v31"
    end

    test "renders one table row per owned document", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "용역계약서 초안"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="document-table")
      assert html =~ ~s(class="document-table")
      assert html =~ ~s(data-role="document-row")
      assert html =~ "용역계약서 초안"
      # Column headers
      assert html =~ "문서명"
      assert html =~ "상태"
      assert html =~ "수정일"
      # No card-namespace classes leaked through.
      refute html =~ "document-card-v31"
      refute html =~ "status-dot-v31"
    end

    test "each row is keyboard-focusable and announced as a link", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _doc} = Documents.create(scope, %{title: "Keyboard nav doc"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Scope the assertion to the <tr> we care about. Other elsewhere
      # in the rendered tree (e.g. layout chrome) may legitimately
      # carry tabindex/role attributes, so we slice to the row first.
      row_html = extract_document_row(html)

      # tabindex=0 + role=link make the row keyboard-focusable; the
      # colocated .DocRow hook handles Enter/Space → click.
      assert row_html =~ ~s(tabindex="0")
      assert row_html =~ ~s(role="link")
      # ColocatedHook compiles ".DocRow" → "ContractWeb.DashboardLive.DocRow"
      # (or similar fully-qualified name). Either form is acceptable
      # as long as the row carries a phx-hook attribute that resolves
      # to the DocRow hook.
      assert row_html =~ "phx-hook="
      assert row_html =~ "DocRow"
    end

    test "clicking a row navigates to /documents/:id", %{conn: conn, scope: scope} do
      {:ok, doc} = Documents.create(scope, %{title: "Row click target"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert lv
             |> element(~s([data-role="document-row"]))
             |> render_click()

      assert_redirect(lv, ~p"/documents/#{doc.id}")
    end

    test "overflow ⋮ button stops propagation so the row click does NOT fire", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _doc} = Documents.create(scope, %{title: "Menu propagation"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # The button must emit a phx:noop dispatch AND stop bubbling so
      # the parent <tr>'s navigate handler does not fire.
      assert html =~ ~s(data-role="document-row-menu")
      assert html =~ ~s|onclick="event.stopPropagation()"|
    end
  end

  describe "table styling (DESIGN section 4 + feedback-review-adds-tests)" do
    setup :register_and_log_in_user

    @app_css "assets/css/app.css"

    test "row has a hover background rule" do
      css = File.read!(@app_css)
      assert css =~ ".document-table__row:hover"
      # hover rule must set a background-color shift to the soft surface.
      assert css =~ "background: var(--cs-surface-soft)"
    end

    test "row has a focus-visible outline rule" do
      css = File.read!(@app_css)
      assert css =~ ".document-table__row:focus-visible"
      assert css =~ "outline: 2px solid var(--cs-blue)"
    end

    test "modification-date column hides on small viewports" do
      css = File.read!(@app_css)

      assert css =~ "@media (max-width: 640px)"
      assert css =~ ".document-table th:nth-child(3)"
      assert css =~ ".document-table td:nth-child(3)"
    end

    test "no .document-card-v31__* CSS survived the table rewrite" do
      css = File.read!(@app_css)

      refute css =~ "document-card-v31"
      refute css =~ "status-dot-v31"
      refute css =~ ".dashboard-v31__grid"
    end

    test "renders ALL owner-scoped documents (not just a recent slice)", %{
      conn: conn,
      scope: scope
    } do
      # Create more docs than the legacy @recent_documents_limit (20) so a
      # naive `list_recent_for_scope(limit: 20)` call would visibly drop
      # entries. The dashboard should still surface every one.
      titles =
        for i <- 1..25 do
          title = "문서 #{i}"
          {:ok, _} = Documents.create(scope, %{title: title})
          title
        end

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      for title <- titles do
        assert html =~ title, "expected dashboard to render document title #{inspect(title)}"
      end
    end
  end

  describe "new_document action" do
    setup :register_and_log_in_user

    test "navigates to /studio without creating a document", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      # Owner starts with zero documents.
      assert Documents.list_recent_for_scope(scope, 5) == []

      lv |> element(~s([data-role="dashboard-new-document"])) |> render_click()

      # The dashboard must NOT mint a document — that responsibility moved
      # to /studio's Canvas.Empty surface (2026-05-17 owner directive).
      assert Documents.list_recent_for_scope(scope, 5) == []
      assert_redirect(lv, ~p"/studio")
    end
  end

  describe "anti-regression (binding feedback + DESIGN.md §7)" do
    setup :register_and_log_in_user

    test "document rows never contain `다음 질문`", %{conn: conn, scope: scope} do
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

    test "Cmd+K trigger is NOT in the navbar (removed 2026-05-17)", %{conn: conn} do
      # Owner stripped the trigger button; keyboard shortcut still works.
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      refute html =~ ~s(data-role="palette-trigger")
    end

    test "global navbar does NOT carry a `계약서 업로드` action", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # The navbar must not surface upload as an anchor/link.
      refute html =~ ~r/<a[^>]*>\s*계약서 업로드/u
    end

    test "dashboard surface does NOT contain `계약서 업로드` anywhere", %{conn: conn} do
      # The 2026-05-17 owner directive moves the upload affordance entirely
      # into /studio. The dashboard must NOT mention `계약서 업로드` —
      # neither in a button, nor in copy, nor in the empty-state hint.
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "계약서 업로드"
    end
  end

  # Slice the first <tr data-role="document-row" ...> ... </tr> out of
  # the rendered HTML so we can assert against row-local attributes
  # without false matches from layout chrome.
  defp extract_document_row(html) do
    case Regex.run(~r/<tr[^>]*data-role="document-row"[^>]*>.*?<\/tr>/s, html) do
      [match] -> match
      _ -> ""
    end
  end
end
