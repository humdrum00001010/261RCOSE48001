defmodule Contract.Workers.ExportJobTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  alias Contract.Export
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

    {:ok, matter} = Contract.Matters.create(scope, %{"name" => "m"})

    {:ok, doc} =
      Contract.Documents.create(scope, %{
        "matter_id" => matter.id,
        "title" => "export-job-fixture",
        "type_key" => "nda_v1"
      })

    {doc.id, scope.user.id}
  end

  describe "perform/1" do
    test "renders HTML, uploads to R2, and broadcasts {:export_ready, export}" do
      {doc_id, requester_id} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      args = %{
        "document_id" => doc_id,
        "format" => "html",
        "requester_id" => requester_id
      }

      assert :ok = perform_job(ExportJob, args)

      # PubSub broadcast lands on the subscribed topic.
      assert_receive {:export_ready, %Export{} = export}, 1_000
      assert export.document_id == doc_id
      assert export.format == :html
      assert export.requester_id == requester_id
      assert export.key |> String.starts_with?("exports/")
      assert export.url |> String.starts_with?("https://stub.r2/exports/")

      # R2 stub recorded the put with the right content-type.
      [{:put, _key, _size, opts}] =
        R2Stub.calls()
        |> Enum.filter(&match?({:put, _, _, _}, &1))

      assert Keyword.get(opts, :content_type) =~ "text/html"

      # Object body is real HTML.
      objects = R2Stub.objects()
      [{key, body}] = Map.to_list(objects)
      assert key == export.key
      assert String.starts_with?(body, "<!doctype html>")
    end

    test "renders HWPX and broadcasts a ready export with format=:hwpx" do
      {doc_id, requester_id} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      args = %{
        "document_id" => doc_id,
        "format" => "hwpx",
        "requester_id" => requester_id
      }

      assert :ok = perform_job(ExportJob, args)
      assert_receive {:export_ready, %Export{format: :hwpx} = export}, 1_000
      assert export.key |> String.ends_with?(".hwpx")

      [{_key, body}] = R2Stub.objects() |> Map.to_list()
      assert <<"PK", _::binary>> = body
    end

    test "broadcasts {:export_failed, id, reason} when R2 put fails" do
      {doc_id, _requester_id} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      R2Stub.fail_next(:put, :boom)

      args = %{
        "document_id" => doc_id,
        "format" => "html",
        "requester_id" => nil
      }

      assert {:error, _} = perform_job(ExportJob, args)
      assert_receive {:export_failed, _export_id, _reason}, 1_000
    end

    test "unsupported format surfaces as a renderer error and failed broadcast" do
      {doc_id, _requester_id} = seed_document()
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, "document:#{doc_id}")

      args = %{"document_id" => doc_id, "format" => "wat", "requester_id" => nil}
      assert {:error, _} = perform_job(ExportJob, args)
      assert_receive {:export_failed, _, {:unsupported_format, :wat}}, 1_000
    end

    test "missing args produces {:error, {:bad_export_args, _}}" do
      assert {:error, {:bad_export_args, _}} = perform_job(ExportJob, %{})
    end
  end

  describe "Runtime.apply/2 → ExportJob enqueue" do
    test "enqueues a job with normalized args" do
      {doc_id, requester_id} = seed_document()
      ctx = nil

      action = %Contract.Command{
        kind: :request_export,
        document_id: doc_id,
        actor_id: requester_id,
        actor_type: :user,
        payload: %{"format" => "html"}
      }

      assert {:ok, %Oban.Job{} = job} = Contract.Runtime.apply(ctx, action)
      assert job.worker == "Contract.Workers.ExportJob"
      assert job.args["document_id"] == doc_id
      assert job.args["format"] == "html"
      assert job.args["requester_id"] == requester_id
      assert job.queue == "export"
    end

    test "missing document_id → {:error, :missing_document_id}" do
      action = %Contract.Command{kind: :request_export, payload: %{"format" => "html"}}
      assert {:error, :missing_document_id} = Contract.Runtime.apply(nil, action)
    end
  end
end
