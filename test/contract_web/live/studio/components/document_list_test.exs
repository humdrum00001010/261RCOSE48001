defmodule ContractWeb.Live.Studio.Components.DocumentListTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.DocumentList

  setup do
    Gettext.put_locale(ContractWeb.Gettext, "en")
    user = user_fixture()
    scope = %Context{Context.for_user(user) | perms: ~w(read write)a}
    %{user: user, scope: scope}
  end

  test "renders document-first empty state with create controls for writers", %{scope: scope} do
    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :no_document, last_seen_revision: 0},
        current_scope: scope
      )

    assert html =~ ~s(data-role="document-list")
    assert html =~ "Documents"
    assert html =~ "Recent documents"
    assert html =~ ~s(data-role="documents-empty")
    assert html =~ ~s(phx-value-modal="new_document")
    refute html =~ "Matter"
    refute html =~ "Workspace"
  end

  test "renders owner-scoped recent documents and selected row", %{scope: scope} do
    {:ok, doc_a} = Documents.create(scope, %{title: "Alpha", type_key: "nda_v1"})
    {:ok, doc_b} = Documents.create(scope, %{title: "Beta", type_key: nil})

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{
          selected_document_id: doc_a.id,
          mode: :editing,
          last_seen_revision: 0
        },
        current_scope: scope
      )

    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ ~s(data-document-id="#{doc_a.id}")
    assert html =~ ~s(data-document-id="#{doc_b.id}")
    assert html =~ ~s(phx-click="document.open")
    assert html =~ ~s(phx-value-document_id="#{doc_a.id}")
    assert html =~ ~r/data-document-id="#{doc_a.id}"[^>]*data-selected="true"/s
  end

  test "treats every non-archived document status as active/current", %{scope: scope} do
    for status <- [:draft, :importing, :editing, :reviewing, :export_ready] do
      {:ok, _doc} = Documents.create(scope, %{title: "#{status} document", status: status})
    end

    {:ok, _archived} = Documents.create(scope, %{title: "Archived document", status: :archived})

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :editing, last_seen_revision: 0},
        current_scope: scope
      )

    assert html =~ ~s(id="doc-list-active")
    assert html =~ ~s(id="doc-list-archived")

    for status <- [:draft, :importing, :editing, :reviewing, :export_ready] do
      assert html =~ "#{status} document"
    end
  end

  test "viewer scope hides create controls", %{user: user} do
    scope = %Context{Context.for_user(user) | perms: ~w(read)a}

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :no_document, last_seen_revision: 0},
        current_scope: scope
      )

    refute html =~ ~s(data-role="new-document-btn")
    refute html =~ ~s(data-role="new-document-empty-cta")
    refute html =~ ~s(phx-value-modal="new_document")
  end

  test "does not fall back to change-derived rows from another owner when scope has no documents",
       %{
         scope: scope
       } do
    other_user = user_fixture()
    other_scope = %Context{Context.for_user(other_user) | perms: ~w(read write)a}

    {:ok, other_doc} =
      Documents.create(other_scope, %{title: "Other owner draft", type_key: "nda_v1"})

    Contract.Repo.insert!(%Contract.Change{
      document_id: other_doc.id,
      command_kind: "edit_document",
      actor_type: :user,
      actor_id: other_user.id,
      result_revision: 1,
      message: "foreign change row"
    })

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :no_document, last_seen_revision: 0},
        current_scope: scope
      )

    assert html =~ ~s(data-role="documents-empty")
    refute html =~ ~s(data-document-id="#{other_doc.id}")
    refute html =~ "Other owner draft"
  end
end
