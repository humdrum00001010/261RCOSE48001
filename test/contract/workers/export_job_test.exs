defmodule Contract.Workers.ExportJobTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  alias Contract.Export
  alias Contract.Repo
  alias Contract.IO.R2Stub
  alias Contract.Workers.ExportJob

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp seed_document do
    # Create a document via the Engine path so Store.load/1 returns a
    # valid State. We use Documents.create which threads through the
    # full Action + Engine + Store pipeline.
    scope = %Contract.Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "x@y"},
      tenant: Ecto.UUID.generate(),
      perms: [:read, :write, :type_change]
    }

    doc_id = Ecto.UUID.generate()

    action = %Contract.Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: scope.user.id,
      base_revision: 0,
      idempotency_key: "create-export-#{doc_id}",
      payload: %{"title" => "export-job-fixture", "type_key" => "nda_v1"}
    }

    {:ok, %Contract.Change{}} = Contract.Runtime.apply(scope, action)

    {doc_id, scope.user.id, scope}
  end

  defp existing_atom?(value) do
    _ = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  describe "perform/1" do
    test "renders Markdown, uploads to R2, persists ready status, and broadcasts export status" do
      {doc_id, requester_id, _scope} = seed_document()
      export_id = Ecto.UUID.generate()
      insert_export!(export_id, doc_id, requester_id, "markdown")
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      args = %{
        "export_id" => export_id,
        "document_id" => doc_id,
        "format" => "markdown",
        "requester_id" => requester_id
      }

      assert :ok = perform_job(ExportJob, args)

      assert_receive {:export_status, %{id: ^export_id, status: :ready, progress: 100}}, 1_000
      assert_receive {:export_ready, %Export{} = export}, 1_000
      assert export.id == export_id
      assert export.document_id == doc_id
      assert export.format == :markdown
      assert export.requester_id == requester_id
      assert export.key |> String.ends_with?(".md")
      assert export.url |> String.starts_with?("/exports/#{export_id}/download")

      persisted = export_record(export_id)
      assert persisted.status == :ready
      assert persisted.progress == 100
      assert persisted.key == export.key
      assert persisted.download_url == export.url

      [{:put, _key, _size, opts}] =
        R2Stub.calls()
        |> Enum.filter(&match?({:put, _, _, _}, &1))

      assert Keyword.get(opts, :content_type) == "text/markdown"

      objects = R2Stub.objects()
      [{key, body}] = Map.to_list(objects)
      assert key == export.key
      assert body =~ "# export-job-fixture"
    end

    test "renders lawyer_packet artifact and persists ready status" do
      {doc_id, requester_id, _scope} = seed_document()
      export_id = Ecto.UUID.generate()
      insert_export!(export_id, doc_id, requester_id, "lawyer_packet")
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      args = %{
        "export_id" => export_id,
        "document_id" => doc_id,
        "format" => "lawyer_packet",
        "requester_id" => requester_id
      }

      assert :ok = perform_job(ExportJob, args)
      assert_receive {:export_status, %{id: ^export_id, status: :ready, progress: 100}}, 1_000
      assert_receive {:export_ready, %Export{format: :lawyer_packet} = export}, 1_000
      assert export.key |> String.ends_with?(".md")

      persisted = export_record(export_id)
      assert persisted.status == :ready
      assert persisted.progress == 100

      [{_key, body}] = R2Stub.objects() |> Map.to_list()
      assert body =~ "# Lawyer Packet:"
      assert body =~ "## Rendered Contract"
      refute body =~ "not_implemented"
    end

    test "broadcasts {:export_failed, id, reason} when R2 put fails" do
      {doc_id, _requester_id, _scope} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      R2Stub.fail_next(:put, :boom)

      args = %{
        "document_id" => doc_id,
        "format" => "markdown",
        "requester_id" => nil
      }

      assert {:error, _} = perform_job(ExportJob, args)
      assert_receive {:export_failed, _export_id, _reason}, 1_000
    end

    test "unsupported formats surface as a renderer error without creating atoms" do
      {doc_id, _requester_id, _scope} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      format = "unsafe_export_format_#{System.unique_integer([:positive])}"
      refute existing_atom?(format)

      args = %{"document_id" => doc_id, "format" => format, "requester_id" => nil}

      assert {:error, {:unsupported_format, ^format}} = perform_job(ExportJob, args)
      assert_receive {:export_failed, _, {:unsupported_format, ^format}}, 1_000
      refute existing_atom?(format)
    end

    test "missing args produces {:error, {:bad_export_args, _}}" do
      assert {:error, {:bad_export_args, _}} = perform_job(ExportJob, %{})
    end
  end

  describe "Runtime.apply/2 → ExportJob enqueue" do
    test "persists a queued export and enqueues a job with normalized args" do
      {doc_id, requester_id, ctx} = seed_document()

      action = %Contract.Command{
        kind: :request_export,
        document_id: doc_id,
        actor_id: requester_id,
        actor_type: :user,
        payload: %{"format" => "markdown"}
      }

      assert {:ok, %Oban.Job{} = job} = Contract.Runtime.apply(ctx, action)
      assert job.worker == "Contract.Workers.ExportJob"
      assert job.args["document_id"] == doc_id
      assert job.args["format"] == "markdown"
      assert job.args["requester_id"] == requester_id
      assert job.queue == "export"
      assert is_binary(job.args["export_id"])

      persisted = export_record(job.args["export_id"])
      assert persisted.document_id == doc_id
      assert persisted.requester_id == requester_id
      assert persisted.format == :markdown
      assert persisted.status == :queued
      assert persisted.progress == 0
    end

    test "missing document_id → {:error, :missing_document_id}" do
      action = %Contract.Command{kind: :request_export, payload: %{"format" => "html"}}
      assert {:error, :missing_document_id} = Contract.Runtime.apply(nil, action)
    end
  end

  defp insert_export!(export_id, doc_id, requester_id, format) do
    %Export{id: export_id}
    |> Export.changeset(%{
      document_id: doc_id,
      requester_id: requester_id,
      format: format,
      status: :queued,
      progress: 0
    })
    |> Repo.insert!()

    export_id
  end

  defp export_record(export_id), do: Repo.get!(Export, export_id)
end
