defmodule Contract.StudioTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Studio
  alias Contract.Studio.State

  defp scope do
    user = %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "studio@example.com"}
    Context.for_user(user)
  end

  describe "load/2" do
    test "loads no-document state when no document_id is supplied" do
      assert {:ok, {%State{} = state, projection}} = Studio.load(scope(), %{})
      assert state.selected_document_id == nil
      assert state.mode == :no_document
      assert projection == Contract.Runtime.State.empty_projection()
    end

    test "loads an owner-scoped document from string-keyed params" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Studio doc"})

      assert {:ok, {%State{} = state, _projection}} = Studio.load(s, %{"document_id" => doc.id})
      assert state.selected_document_id == doc.id
      assert state.mode == :briefing
    end

    test "rejects a document owned by another user" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Private"})

      assert {:error, :forbidden} = Studio.load(other, %{"document_id" => doc.id})
    end
  end

  describe "list/search documents" do
    test "list_documents/1 returns owner-scoped rows" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Visible", type_key: "nda_v1"})

      assert [%{document_id: id, title: "Visible"}] = Studio.list_documents(s)
      assert id == doc.id
    end

    test "search_documents/2 returns owner-scoped matches" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Needle draft", type_key: nil})

      assert [%{document_id: id, title: "Needle draft"}] = Studio.search_documents(s, "Needle")
      assert id == doc.id
    end
  end
end
