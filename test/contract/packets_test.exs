defmodule Contract.PacketsTest do
  use Contract.DataCase, async: false

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Packets
  alias Contract.Packets.Packet
  alias Contract.Packets.PacketDocument

  defp scope do
    %Context{
      user: %Contract.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "u#{System.unique_integer([:positive])}@x"
      }
    }
  end

  defp create_packet!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Packet #{System.unique_integer([:positive])}"}, attrs)
    {:ok, packet} = Packets.create_packet(scope, attrs)
    packet
  end

  defp create_document!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Doc #{System.unique_integer([:positive])}"}, attrs)
    {:ok, document} = Documents.create(scope, attrs)
    document
  end

  describe "create/list/update" do
    test "creates owner-scoped packets and lists only owned packets" do
      owner = scope()
      other = scope()

      packet =
        create_packet!(owner, %{
          owner_id: other.user.id,
          title: "Acme NDA",
          counterparty: "Acme",
          metadata: %{"source" => "test"}
        })

      _hidden = create_packet!(other, %{title: "Hidden"})

      assert packet.owner_id == owner.user.id
      assert packet.title == "Acme NDA"
      assert packet.counterparty == "Acme"
      assert packet.status == "active"
      assert packet.metadata == %{"source" => "test"}

      assert [%Packet{id: id}] = Packets.list_packets_for_scope(owner)
      assert id == packet.id
      assert Packets.list_packets_for_scope(%Context{user: nil}) == []
    end

    test "anonymous create is forbidden" do
      assert {:error, :forbidden} =
               Packets.create_packet(%Context{user: nil}, %{title: "Nope"})
    end

    test "update_packet/3 enforces owner ACL" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner, %{title: "Old"})

      assert {:ok, %Packet{title: "New"}} =
               Packets.update_packet(owner, packet, %{title: "New"})

      assert {:error, :forbidden} =
               Packets.update_packet(other, packet, %{title: "Other"})
    end
  end

  describe "delete_packet/2" do
    test "deletes owned packet and archives documents with no remaining packet refs" do
      owner = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      assert {:ok, %Packet{id: deleted_id}} = Packets.delete_packet(owner, packet.id)
      assert deleted_id == packet.id

      assert {:error, :not_found} = Packets.get_packet(owner, packet.id)
      assert %Document{status: :archived} = Repo.get!(Document, document.id)
      assert {:ok, 0} = Packets.document_ref_count(owner, document.id)
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: document.id) == nil
    end

    test "deleting one packet leaves documents active when another packet still references them" do
      owner = scope()
      first = create_packet!(owner)
      second = create_packet!(owner)
      document = create_document!(owner)

      {:ok, _packet_document} = Packets.attach_document(owner, first.id, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, second.id, document.id)

      assert {:ok, 2} = Packets.document_ref_count(owner, document.id)
      assert {:ok, %Packet{id: deleted_id}} = Packets.delete_packet(owner, first.id)
      assert deleted_id == first.id

      assert %Document{status: :draft} = Repo.get!(Document, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      assert Repo.get_by(PacketDocument, packet_id: first.id, document_id: document.id) == nil
      assert Repo.get_by(PacketDocument, packet_id: second.id, document_id: document.id)
    end

    test "delete_packet/2 enforces owner ACL" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)

      assert {:error, :forbidden} = Packets.delete_packet(other, packet.id)
      assert {:error, :forbidden} = Packets.delete_packet(%Context{user: nil}, packet.id)
      assert {:ok, %Packet{id: packet_id}} = Packets.get_packet(owner, packet.id)
      assert packet_id == packet.id
    end
  end

  describe "get_packet/2" do
    test "enforces owner ACL and preloads linked documents" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, %Packet{} = loaded} = Packets.get_packet(owner, packet.id)
      assert Enum.map(loaded.documents, & &1.id) == [document.id]

      assert [%PacketDocument{document: %Document{id: document_id}}] =
               loaded.packet_documents

      assert document_id == document.id
      assert {:error, :forbidden} = Packets.get_packet(other, packet.id)
      assert {:error, :not_found} = Packets.get_packet(owner, Ecto.UUID.generate())
    end
  end

  describe "packet documents" do
    test "same document can be attached to two packets" do
      owner = scope()
      first = create_packet!(owner, %{title: "First"})
      second = create_packet!(owner, %{title: "Second"})
      document = create_document!(owner)

      assert {:ok, %PacketDocument{}} = Packets.attach_document(owner, first.id, document.id)
      assert {:ok, %PacketDocument{}} = Packets.attach_document(owner, second.id, document.id)

      count =
        PacketDocument
        |> where([pd], pd.document_id == ^document.id)
        |> Repo.aggregate(:count)

      assert count == 2
      assert {:ok, 2} = Packets.document_ref_count(owner, document.id)
    end

    test "packet_for_document/2 returns an owned packet for attached document" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      other_document = create_document!(other)

      assert {:error, :not_found} = Packets.packet_for_document(owner, document.id)

      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, %Packet{id: packet_id}} = Packets.packet_for_document(owner, document.id)
      assert packet_id == packet.id
      assert {:error, :forbidden} = Packets.packet_for_document(other, document.id)
      assert {:error, :forbidden} = Packets.packet_for_document(owner, other_document.id)

      assert {:error, :forbidden} =
               Packets.packet_for_document(%Context{user: nil}, document.id)
    end

    test "cannot attach another owner's document" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      other_document = create_document!(other)

      assert {:error, :forbidden} =
               Packets.attach_document(owner, packet.id, other_document.id)

      assert Repo.aggregate(PacketDocument, :count) == 0
    end

    test "re-attaching same document returns existing join row" do
      owner = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)

      assert {:ok, %PacketDocument{} = first} =
               Packets.attach_document(owner, packet.id, document.id, %{role: "source"})

      assert {:ok, %PacketDocument{} = second} =
               Packets.attach_document(owner, packet.id, document.id, %{role: "review"})

      assert second.id == first.id
      assert second.role == "source"
      assert Repo.aggregate(PacketDocument, :count) == 1
    end

    test "document_ref_count/2 is owner scoped" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      other_document = create_document!(other)

      assert {:ok, 0} = Packets.document_ref_count(owner, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)

      assert {:error, :forbidden} = Packets.document_ref_count(other, document.id)
      assert {:error, :forbidden} = Packets.document_ref_count(owner, other_document.id)
      assert {:error, :forbidden} = Packets.document_ref_count(%Context{user: nil}, document.id)
      assert {:error, :not_found} = Packets.document_ref_count(owner, Ecto.UUID.generate())
    end

    test "detach removes last membership and archives orphaned document" do
      owner = scope()
      packet = create_packet!(owner)
      attached = create_document!(owner, %{title: "Attached"})
      available = create_document!(owner, %{title: "Available"})

      assert available_document_ids(owner, packet.id) == Enum.sort([available.id, attached.id])

      assert {:ok, _packet_document} = Packets.attach_document(owner, packet.id, attached.id)
      assert available_document_ids(owner, packet.id) == [available.id]

      assert :ok = Packets.detach_document(owner, packet.id, attached.id)
      assert %Document{status: :archived} = Repo.get!(Document, attached.id)
      assert {:ok, 0} = Packets.document_ref_count(owner, attached.id)
      assert available_document_ids(owner, packet.id) == [available.id]

      assert :ok = Packets.detach_document(owner, packet.id, attached.id)
    end

    test "detach from one of two packets leaves shared document active" do
      owner = scope()
      first = create_packet!(owner)
      second = create_packet!(owner)
      document = create_document!(owner)

      {:ok, _packet_document} = Packets.attach_document(owner, first.id, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, second.id, document.id)

      assert :ok = Packets.detach_document(owner, first.id, document.id)

      assert %Document{status: :draft} = Repo.get!(Document, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      assert available_document_ids(owner, first.id) == [document.id]
      assert available_document_ids(owner, second.id) == []
    end
  end

  defp available_document_ids(scope, packet_id) do
    scope
    |> Packets.list_available_documents(packet_id)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
