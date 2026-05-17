defmodule Contract.ExportPersistenceTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  alias Contract.Command
  alias Contract.Context
  alias Contract.Export
  alias Contract.Repo
  alias Contract.Runtime

  test "requesting markdown and lawyer_packet creates persisted export rows" do
    ctx = scope()
    markdown_doc_id = create_owned_doc(ctx, title: "Markdown export doc")
    packet_doc_id = create_owned_doc(ctx, title: "Packet export doc")

    for {doc_id, format} <- [{markdown_doc_id, "markdown"}, {packet_doc_id, "lawyer_packet"}] do
      action = %Command{
        kind: :request_export,
        document_id: doc_id,
        actor_type: :user,
        actor_id: ctx.user.id,
        payload: %{"format" => format}
      }

      assert {:ok, %Oban.Job{} = job} = Runtime.apply(ctx, action)
      assert job.args["format"] == format
      assert is_binary(job.args["export_id"])

      export = Repo.get!(Export, job.args["export_id"])
      assert export.document_id == doc_id
      assert export.requester_id == ctx.user.id
      assert Atom.to_string(export.format) == format
      assert export.status == :queued
      assert export.progress == 0
    end
  end

  test "requesting html as a product-facing export format is rejected" do
    ctx = scope()
    doc_id = create_owned_doc(ctx, title: "No HTML export doc")

    action = %Command{
      kind: :request_export,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      payload: %{"format" => "html"}
    }

    assert {:error, {:unsupported_export_format, "html"}} = Runtime.apply(ctx, action)
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "export-persistence-#{user_id}@example.test"
      }
    }
  end

  defp create_owned_doc(%Context{} = ctx, opts) do
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-export-persistence-#{doc_id}",
      payload: %{"title" => Keyword.fetch!(opts, :title), "type_key" => "nda_v1"}
    }

    {:ok, %Contract.Change{}} = Runtime.apply(ctx, action)
    doc_id
  end
end
