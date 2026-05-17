defmodule ContractWeb.ExportDownloadControllerTest do
  use ContractWeb.ConnCase, async: false

  import Contract.AccountsFixtures

  alias Contract.Documents
  alias Contract.Export
  alias Contract.IO.R2Stub
  alias Contract.Repo

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  test "GET /exports/:export_id/download streams the owner's ready export", %{conn: conn} do
    owner = user_fixture()
    scope = Contract.Context.for_user(owner)
    {:ok, document} = Documents.create(scope, %{title: "Download ACL", type_key: "nda_v1"})

    export_id = Ecto.UUID.generate()
    key = "exports/#{export_id}.md"
    {:ok, _} = R2Stub.put(key, "# Download ACL
body", content_type: "text/markdown")
    insert_export!(export_id, document.id, owner.id, key)

    conn =
      conn
      |> log_in_user(owner)
      |> get("/exports/#{export_id}/download")

    assert response(conn, 200) == "# Download ACL
body"
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
  end

  test "GET /exports/:export_id/download rejects a different owner", %{conn: conn} do
    owner = user_fixture()
    other = user_fixture()
    scope = Contract.Context.for_user(owner)
    {:ok, document} = Documents.create(scope, %{title: "Private Export", type_key: "nda_v1"})

    export_id = Ecto.UUID.generate()
    key = "exports/#{export_id}.md"
    {:ok, _} = R2Stub.put(key, "private", content_type: "text/markdown")
    insert_export!(export_id, document.id, owner.id, key)

    conn =
      conn
      |> log_in_user(other)
      |> get("/exports/#{export_id}/download")

    assert response(conn, 404)
  end

  defp insert_export!(export_id, document_id, requester_id, key) do
    %Export{id: export_id}
    |> Export.changeset(%{
      document_id: document_id,
      requester_id: requester_id,
      format: :markdown,
      status: :ready,
      progress: 100,
      key: key,
      download_url: "/exports/#{export_id}/download",
      content_type: "text/markdown",
      byte_size: 19
    })
    |> Repo.insert!()
  end
end
