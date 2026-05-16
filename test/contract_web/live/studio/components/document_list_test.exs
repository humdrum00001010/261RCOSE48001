defmodule ContractWeb.Live.Studio.Components.DocumentListTest do
  @moduledoc """
  Component-level tests for `DocumentList`. We render through
  `Phoenix.LiveViewTest.render_component/2`, which exercises `update/2` and
  the rendered HTML for a LiveComponent.

  LV-level tests for the studio shell (mount, viewport, modal-host) live in
  `studio_live_test.exs` — we don't duplicate them here.
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.DocumentList

  # The studio surface is Korean-primary. `config/test.exs` pins the
  # global UI locale to "en" so the gen.auth + dashboard suites match
  # the English msgids that serve as translation source-of-truth. The
  # studio component renders assert on Korean msgstrs, so we explicitly
  # flip the process-local Gettext locale to "ko" for each test here.
  # Each test runs in its own process so no teardown is necessary —
  # `Gettext.put_locale/2` writes to the process dictionary.
  setup do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    :ok
  end

  # --- persona-perm fixtures (mirror Contract.PersonaFactory) ----------

  defp lawyer_scope(user, matter \\ nil) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a,
        matter: matter
    }
  end

  defp paralegal_scope(user, matter) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a,
        matter: matter
    }
  end

  defp viewer_scope(user, matter) do
    %Context{Context.for_user(user) | perms: ~w(read)a, matter: matter}
  end

  defp blank_state(opts \\ []) do
    %State{
      matter_id: Keyword.get(opts, :matter_id),
      selected_document_id: Keyword.get(opts, :selected_document_id),
      mode: :no_document,
      last_seen_revision: 0
    }
  end

  defp insert_change!(attrs) do
    Contract.Repo.insert!(
      struct(Contract.Change, [
        action_kind: "edit_document",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 1,
        status: :active
      ] ++ Map.to_list(Map.new(attrs)))
    )
  end

  # --- 1. empty state --------------------------------------------------

  describe "empty state" do
    test "renders the Korean empty copy and a + 새 문서 CTA for lawyers" do
      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "Acme M&A"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: lawyer_scope(user, matter)
        )

      assert html =~ "아직 문서가 없습니다"
      assert html =~ ~s(data-role="documents-empty")
      assert html =~ ~s(data-role="new-document-empty-cta")
      # Header button + empty-state CTA both fire open_modal with new_document.
      assert html =~ ~s(phx-click="open_modal")
      assert html =~ ~s(phx-value-modal="new_document")
      # Matter header shows the matter name.
      assert html =~ "Acme M&amp;A"
    end
  end

  # --- 2. persona perm gating ------------------------------------------

  describe "persona perms — :viewer is read-only" do
    test "hides every + 새 문서 control when scope is :viewer" do
      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "View-only matter"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: viewer_scope(user, matter)
        )

      # Top-right header button — gone.
      refute html =~ ~s(data-role="new-document-btn")
      # Empty-state CTA — gone.
      refute html =~ ~s(data-role="new-document-empty-cta")
      # And to be safe: no open_modal phx-click anywhere for new_document.
      refute html =~ ~s(phx-value-modal="new_document")
      # But the empty copy is still rendered (viewer still sees the panel).
      assert html =~ "아직 문서가 없습니다"
    end

    test "shows the + 새 문서 controls for paralegal (has :write perm)" do
      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "Paralegal-driven matter"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: paralegal_scope(user, matter)
        )

      assert html =~ ~s(data-role="new-document-btn")
      assert html =~ ~s(data-role="new-document-empty-cta")
    end
  end

  # --- 3. populated tree + selection -----------------------------------

  describe "populated document tree" do
    test "renders active documents grouped under 활성 / Active and highlights selected" do
      user = user_fixture()
      matter_id = Ecto.UUID.generate()
      matter = %{id: matter_id, name: "Acme acquisition"}

      doc_a = Ecto.UUID.generate()
      doc_b = Ecto.UUID.generate()

      insert_change!(%{document_id: doc_a, matter_id: matter_id, applied_revision: 1})
      insert_change!(%{document_id: doc_b, matter_id: matter_id, applied_revision: 2})

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state:
            blank_state(matter_id: matter_id, selected_document_id: doc_a),
          current_scope: lawyer_scope(user, matter)
        )

      # Active heading present, archived absent.
      assert html =~ "활성"
      refute html =~ "보관"

      # Both documents are rendered as rows (assert by data-document-id).
      assert html =~ ~s(data-document-id="#{doc_a}")
      assert html =~ ~s(data-document-id="#{doc_b}")

      # Selected document carries aria-current="true".
      assert html =~ ~r/data-document-id="#{doc_a}"[^>]*?data-selected="true"/s or
               html =~ ~r/data-selected="true"[^>]*?data-document-id="#{doc_a}"/s

      # Click handler is wired correctly.
      assert html =~ ~s(phx-click="open_document")
      assert html =~ ~s(phx-value-document_id="#{doc_a}")
      # Empty state should NOT render alongside the tree.
      refute html =~ ~s(data-role="documents-empty")
    end

    test "revoked documents bucket into 보관 / Archived" do
      user = user_fixture()
      matter_id = Ecto.UUID.generate()
      matter = %{id: matter_id, name: "Mixed bag"}

      live_doc = Ecto.UUID.generate()
      revoked_doc = Ecto.UUID.generate()

      insert_change!(%{document_id: live_doc, matter_id: matter_id, status: :active})
      insert_change!(%{document_id: revoked_doc, matter_id: matter_id, status: :revoked})

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter_id),
          current_scope: lawyer_scope(user, matter)
        )

      assert html =~ "활성"
      assert html =~ "보관"
      assert html =~ ~s(data-document-id="#{live_doc}")
      assert html =~ ~s(data-document-id="#{revoked_doc}")
    end
  end

  # --- 4. responsive layout --------------------------------------------

  describe "responsive layout" do
    test "default / :desktop layout is 280px wide with a right border" do
      user = user_fixture()

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(),
          current_scope: lawyer_scope(user)
        )

      assert html =~ ~s(data-layout="desktop")
      assert html =~ "w-[280px]"
      assert html =~ "border-r"
    end

    test ":drawer layout drops the standalone width + border (parent owns chrome)" do
      user = user_fixture()

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(),
          current_scope: lawyer_scope(user),
          layout: :drawer
        )

      assert html =~ ~s(data-layout="drawer")
      refute html =~ "w-[280px]"
      refute html =~ "border-r"
    end
  end

  # --- 5. event-dispatch shape -----------------------------------------

  describe "event dispatch" do
    test "open_document click emits the right phx-value-document_id for the row" do
      user = user_fixture()
      matter_id = Ecto.UUID.generate()
      matter = %{id: matter_id, name: "Click target"}

      doc = Ecto.UUID.generate()
      insert_change!(%{document_id: doc, matter_id: matter_id})

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter_id),
          current_scope: lawyer_scope(user, matter)
        )

      # The row's phx-click name + phx-value-document_id pair must be the
      # exact shape `StudioLive.event_to_action("open_document", _)` expects.
      assert html =~ ~s(phx-click="open_document")
      assert html =~ ~s(phx-value-document_id="#{doc}")
    end

    test "new-document button (and empty CTA) emit open_modal with modal=new_document" do
      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "CTA matter"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: lawyer_scope(user, matter)
        )

      # 2 buttons in empty state (header + body), one of each event.
      assert html =~ ~s(phx-click="open_modal")
      assert html =~ ~s(phx-value-modal="new_document")
    end
  end

  # --- 6. workspace (Matter) header fallback ---------------------------

  describe "workspace header" do
    test "renders fallback Korean label when scope.matter is nil (Document-pivot label: 워크스페이스)" do
      user = user_fixture()

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(),
          current_scope: lawyer_scope(user, nil)
        )

      # Post-Document-pivot: the user-facing label is "워크스페이스" and
      # the empty fallback uses 워크스페이스, never the legacy "사건".
      assert html =~ "워크스페이스 미선택"
      refute html =~ "사건 미선택"
      refute html =~ "사건"
    end
  end

  # --- 7. i18n: single-language rendering (no bilingual concatenation) -

  describe "i18n — single-language rendering" do
    test "renders Korean-only labels in :ko locale (no bilingual concatenation)" do
      # `setup` already put locale to "ko"; re-asserting here for clarity.
      Gettext.put_locale(ContractWeb.Gettext, "ko")

      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "i18n matter"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: lawyer_scope(user, matter)
        )

      # Korean msgstrs are present — header label is now "워크스페이스"
      # (Document-pivot) and never "사건" / "안건".
      assert html =~ "워크스페이스"
      refute html =~ "사건"
      refute html =~ "안건"
      assert html =~ "아직 문서가 없습니다"
      assert html =~ "계약 유형을 골라 첫 초안을 시작하세요"

      # English msgids must NOT leak into the :ko render.
      refute html =~ "WORKSPACE"
      refute html =~ "MATTER"
      refute html =~ "No documents yet"
      refute html =~ "Pick a contract type"

      # The slash-separated bilingual form must not appear anywhere.
      refute html =~ "워크스페이스 / Workspace"
      refute html =~ "/ Workspace"
      refute html =~ "/ Matter"
      refute html =~ "아직 문서가 없습니다 / No documents yet"
      refute html =~ "/ No documents yet"
    end

    test "renders English fallback labels in :en locale" do
      Gettext.put_locale(ContractWeb.Gettext, "en")

      user = user_fixture()
      matter = %{id: Ecto.UUID.generate(), name: "en matter"}

      html =
        render_component(DocumentList,
          id: "doc-list",
          studio_state: blank_state(matter_id: matter.id),
          current_scope: lawyer_scope(user, matter)
        )

      # English msgids appear (msgstr is empty in en/LC_MESSAGES → falls
      # back to msgid). Post-Document-pivot the header reads
      # "Workspace", never "Matter".
      assert html =~ "Workspace"
      refute html =~ ~s(>Matter<)
      assert html =~ "No documents yet"
      assert html =~ "Pick a contract type to start your first draft."

      # Korean msgstrs do NOT leak into the :en render.
      refute html =~ "워크스페이스"
      refute html =~ "사건"
      refute html =~ "안건"
      refute html =~ "아직 문서가 없습니다"
      refute html =~ "계약 유형"

      # And the bilingual slash form is gone here too.
      refute html =~ "/ WORKSPACE"
      refute html =~ "워크스페이스 / Workspace"
    end
  end
end
