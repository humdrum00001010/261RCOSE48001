defmodule ContractWeb.StudioLiveDocumentFirstTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Studio.State
  alias ContractWeb.StudioLive

  setup :register_and_log_in_user

  test "authenticated document route mounts owner-scoped Studio", %{conn: conn, scope: scope} do
    {:ok, doc} = Documents.create(scope, %{title: "Owner draft", type_key: "nda_v1"})

    {:ok, lv, html} = live(conn, ~p"/documents/#{doc.id}")

    assert html =~ ~s(id="studio-root")
    assert :sys.get_state(lv.pid).socket.assigns.studio_state.selected_document_id == doc.id
  end

  test "document route does not mount a document owned by a different user", %{conn: conn} do
    other_user = Contract.AccountsFixtures.user_fixture()
    other_scope = Context.for_user(other_user)
    {:ok, other_doc} = Documents.create(other_scope, %{title: "Other owner draft"})

    {:ok, lv, _html} = live(conn, ~p"/documents/#{other_doc.id}")

    assigns = :sys.get_state(lv.pid).socket.assigns
    assert assigns.studio_state.selected_document_id == nil
    assert assigns.studio_state.mode == :no_document
  end

  test "dotted UI events build document-first commands without matter fields", %{scope: scope} do
    doc_id = Ecto.UUID.generate()

    assigns = %{
      current_scope: scope,
      studio_state: %State{selected_document_id: doc_id, last_seen_revision: 7, mode: :editing}
    }

    assert {:ok, %Command{} = command} =
             StudioLive.event_to_command("chat.submit", %{"message" => "Review this"}, assigns)

    assert command.kind == :chat_message
    assert command.document_id == doc_id
    assert command.chat_thread_id == nil
    refute Map.has_key?(Map.from_struct(command), :matter_id)
  end
end
