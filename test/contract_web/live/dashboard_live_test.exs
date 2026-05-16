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

    test "renders the welcome heading + the two stat cards (Document-pivot: no Active matters stat)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Good day"
      assert html =~ "Documents"
      assert html =~ "Open agent runs"

      # Document-pivot (SPEC.md 2026-05-15): the user-facing label
      # "Matter" / "안건" / "사건" must NOT appear on the dashboard.
      refute html =~ "Active matters"
      refute html =~ "Matters"
      refute html =~ "안건"
      refute html =~ "사건"
    end

    test "shows the persona dropdown with the user's email in the navbar",
         %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ user.email
      assert html =~ "Log out"
    end
  end

  describe "empty state (Document-pivot — no Matters section)" do
    setup :log_in_a_user

    test "Matters dashboard section is NOT rendered, even when no matters exist",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Per SPEC.md (Document-pivot) the Matters section is gone from
      # the dashboard entirely — neither the table nor the
      # illustration empty-state should appear.
      refute html =~ ~s(id="matters-empty")
      refute html =~ ~s(id="matters-table")
      refute html =~ ~s(id="matters-grid")
      refute html =~ "No matters yet"
      refute html =~ "New Matter"
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

  describe "new-document modal (SPEC.md §18 — type set later)" do
    setup :log_in_a_user

    test "opens the modal with a title input — no contract-type picker", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute render(lv) =~ ~s(id="new-document-modal")

      html =
        lv
        |> element("button", "New Document")
        |> render_click()

      assert html =~ ~s(id="new-document-modal")
      # Title input is the only required field; no type list anymore.
      assert html =~ ~s(data-role="new-document-form")
      assert html =~ ~s(name="title")
      # Hint copy is shipped.
      assert html =~ ~s(data-role="new-document-type-hint")

      # The old contract-type picker must NOT render — no type-key
      # buttons, no `id="contract-type-list"`, and no raw type keys.
      refute html =~ ~s(id="contract-type-list")
      refute html =~ ~s(phx-click="pick_type")
      refute html =~ ~s(phx-value-type_key="nda_v1")
    end

    test "closing the modal hides it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()
      assert render(lv) =~ ~s(id="new-document-modal")

      lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute render(lv) =~ ~s(id="new-document-modal")
    end

    # Submitting a title creates an untyped document and flashes the
    # "set type via Cmd+K or agent" prompt. This is the headline
    # behaviour of the subagent fix.
    test "submitting a title creates an untyped document", %{conn: conn, user: user} do
      # The dashboard's fallback path needs at least one matter the
      # scope can see; seed one before opening the modal.
      scope = Contract.Context.for_user(user)
      {:ok, _matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()

      html =
        lv
        |> form(~s(form[data-role="new-document-form"]), %{"title" => "Quick draft"})
        |> render_submit()

      refute html =~ ~s(id="new-document-modal")
      # Flash mentions Cmd+K / agent so the user knows where the type
      # is now set.
      assert html =~ "Cmd+K" or html =~ "agent"

      # And a document was actually persisted, untyped.
      [doc] = Contract.Documents.list_recent_for_scope(scope, 5)
      assert doc.title == "Quick draft"
      assert doc.type_key == nil
    end
  end

  describe "documents + activity populated state" do
    setup :log_in_a_user

    # Wave 4: the dashboard now reads real Matters + Documents rows.
    # We seed both, plus a couple of Change rows for the activity feed,
    # and assert the populated branches render.
    test "renders the documents list + activity feed when matters and documents exist",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Test matter"})

      {:ok, doc_a} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Doc A",
          "type_key" => "nda_v1"
        })

      {:ok, doc_b} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Doc B",
          "type_key" => "service_agreement_v1"
        })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_a.id,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 1,
        message: "first commit on A"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_a.id,
        action_kind: "rename_document",
        actor_type: :agent,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 2,
        message: "rename"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_b.id,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 1,
        message: "first commit on B"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Recent-documents section: populated branch.
      assert html =~ ~s(id="documents-list")
      refute html =~ ~s(id="documents-empty")
      assert html =~ "Doc A"
      assert html =~ "Doc B"

      # Activity section: populated branch.
      assert html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="activity-empty")
      assert html =~ "first commit on A"
      assert html =~ "rename"

      # Stat row.
      assert html =~ "Documents"
      assert html =~ "Open agent runs"

      # Document-pivot: "Active matters" stat is gone.
      refute html =~ "Active matters"
    end
  end

  # ---------------------------------------------------------------------------
  # Document-pivot (SPEC.md 2026-05-15): the dashboard Matters section
  # is GONE. Tests below pin that behaviour — neither the empty-state
  # illustration nor the populated table should render, no matter how
  # many matters exist on the scope.
  # ---------------------------------------------------------------------------
  describe "matters section is hidden (Document-pivot)" do
    setup :log_in_a_user

    test "does not render the matters table even when matters exist",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="matters-table")
      refute html =~ ~s(id="matters-empty")
      refute html =~ ~s(id="matters-grid")
      refute html =~ "New Matter"
      refute html =~ "Active matters"
    end

    test "matter names never leak into the dashboard chrome",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _m1} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})
      {:ok, _m2} = Contract.Matters.create(scope, %{"name" => "Doe Estate"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # No matter section header, no individual matter rows.
      refute html =~ ~s(id="matters")
      # Stat row no longer mentions matters.
      refute html =~ "Active matters"
      # Casual-UI Korean labels for "matter" / "case" must not appear.
      refute html =~ "안건"
      refute html =~ "사건"
    end
  end

  describe "recent documents table (populated state)" do
    setup :log_in_a_user

    test "renders a <table> with Title / Type / Status / Last revision columns (Document-pivot: no Matter column)",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Table shell.
      assert html =~ ~s(id="documents-list")
      assert html =~ "<table"

      # Column headers — Matter column was dropped per Document-pivot.
      assert html =~ "Title"
      assert html =~ "Type"
      assert html =~ "Last revision"

      # Document title renders. The Matter column header should be
      # gone — but the row's `~p"/matters/..."` href still resolves
      # to a string containing "matter", so we cannot refute the
      # substring directly. Pin the absence of the dedicated
      # `<th>Matter</th>` header instead.
      refute html =~ ~s(>Matter</th>)
      refute html =~ ~s(>Matter\n</th>)

      assert html =~ "Engagement letter"
    end

    # SPEC.md §18 — `feat/no-type-at-create`: when a document is
    # created untyped (type_key: nil), the Type column renders the
    # locale-aware "유형 미지정" placeholder so the row still
    # parses at a glance.
    test "renders 유형 미지정 placeholder for untyped documents under :ko locale",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "ko")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Untyped draft"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Untyped draft"
      assert html =~ "유형 미지정"
    end

    # Wave 5: the subagent fix — the Type column used to render the raw
    # `type_key` ("nda_v1") regardless of locale. With locale-aware
    # `Contract.ContractTypes.display_name/1`, Korean lawyers should see
    # the Korean name from the TOML spec.
    test "renders the localized contract-type name in the Type column under :ko locale",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "ko")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Korean name from priv/contract_types/nda_v1.toml.
      {:ok, spec} = Contract.ContractTypes.get(nil, "nda_v1")
      assert html =~ spec.name_ko

      # The Type cell badge text is now the Korean label, not raw
      # "nda_v1". The key is still present as a `title=` tooltip for
      # power users, so the bare-key assertion would still spuriously
      # match — pin the badge slot specifically.
      assert html =~ ~s(badge badge-ghost badge-sm" title="nda_v1")
    end
  end

  # ---------------------------------------------------------------------------
  # Document-pivot audit (SPEC.md 2026-05-15 — Required framing).
  #
  # User-facing label policy: "Workspace" / "워크스페이스" or hidden;
  # "Matter" / "안건" / "사건" must NOT surface in casual UI. The audit
  # walks the rendered dashboard HTML and pins these substrings as
  # absent. Backend symbols (`matter_id` in form names, `~p"/matters/..."`
  # URL paths, comments inside `<script>` blocks) are out of scope —
  # we exclude them with explicit assertion shapes.
  # ---------------------------------------------------------------------------
  describe "Document-pivot label-audit (no Matter/안건/사건 in casual UI)" do
    setup :log_in_a_user

    test "casual UI does NOT contain the words 'Matter' / 'Matters' / 'New Matter' as visible labels",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Background workspace"})

      # Populate at least one document so the recent-documents table renders.
      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # User-facing strings — must be gone.
      refute html =~ "Active matters"
      refute html =~ "Matters"
      refute html =~ "New Matter"
      refute html =~ "No matters yet"
      # The Matter column header on the recent-documents table is gone.
      refute html =~ ~s(>Matter</th>)
      # And the seeded matter name itself should not leak as a section
      # heading — it might still appear inside a row's hidden /matters/
      # URL, but never as a free-floating label.
      refute html =~ ~s(<h2 class="text-lg font-semibold tracking-tight">\n              Background workspace)
    end

    test "casual UI does NOT contain the Korean labels '안건' or '사건'",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "안건"
      refute html =~ "사건"
    end
  end

  # ---------------------------------------------------------------------------
  # Activity-feed action verb localization (#93).
  #
  # Before: the feed rendered the raw `action_kind` string ("edit_document",
  # "set_contract_type") — English snake-case bled into a Korean dashboard.
  # After: an `action_kind_label/1` private helper routes known kinds
  # through dgettext("dashboard", ...) so :ko renders Korean ("문서 편집")
  # and :en renders the human-readable English msgid ("edited document").
  # Unknown kinds fall back to `to_string/1` so we never crash on a new
  # action_kind landing before its label is wired up.
  # ---------------------------------------------------------------------------
  describe "activity-feed action verbs (#93 — Korean localization)" do
    setup :log_in_a_user

    test ":ko locale renders 문서 편집 instead of raw 'edit_document'",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "ko")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        action_kind: "edit_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 2,
        message: "tightened §3"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="activity-feed")
      assert html =~ "문서 편집"
      # The raw English snake-case form must NOT leak into the Korean
      # casual UI — pin both the underscored kind and the English label.
      refute html =~ "edit_document"
      refute html =~ "edited document"
    end

    test ":en locale renders the English msgid fallback ('edited document')",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "en")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        action_kind: "edit_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 2,
        message: "tightened §3"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="activity-feed")
      assert html =~ "edited document"
      # No raw snake-case leakage even on :en.
      refute html =~ "edit_document"
    end

    test "unknown action_kind falls back to to_string/1 (never crashes the feed)",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      # A brand-new action_kind that the label table doesn't know about.
      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        action_kind: "fancy_new_kind",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 1,
        message: "future action"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="activity-feed")
      # Falls back to the raw kind string — better than a 500.
      assert html =~ "fancy_new_kind"
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
