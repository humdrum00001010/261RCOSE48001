defmodule ContractWeb.RhwpSnapshotControllerTest do
  use ContractWeb.ConnCase, async: false

  import Contract.AccountsFixtures

  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.RhwpSnapshot.Record

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  test "GET /documents/:document_id/rhwp-snapshots/:revision.hwp streams the owner's native snapshot",
       %{conn: conn} do
    owner = user_fixture()
    scope = Contract.Context.for_user(owner)
    {:ok, document} = Documents.create(scope, %{title: "Snapshot ACL", type_key: "nda_v1"})
    key = "documents/#{document.id}/snapshots/1.hwp"

    {:ok, _} = R2Stub.put(key, "hwp-bytes", content_type: "application/x-hwp")
    insert_snapshot!(document.id, 1, key, "hwp")

    conn =
      conn
      |> log_in_user(owner)
      |> get("/documents/#{document.id}/rhwp-snapshots/1.hwp")

    assert response(conn, 200) == "hwp-bytes"
    assert get_resp_header(conn, "content-type") == ["application/x-hwp"]
  end

  test "GET /documents/:document_id/rhwp-snapshots/:revision.hwp rejects a different owner",
       %{conn: conn} do
    owner = user_fixture()
    other = user_fixture()
    scope = Contract.Context.for_user(owner)
    {:ok, document} = Documents.create(scope, %{title: "Private Snapshot", type_key: "nda_v1"})
    key = "documents/#{document.id}/snapshots/1.hwp"

    {:ok, _} = R2Stub.put(key, "private", content_type: "application/x-hwp")
    insert_snapshot!(document.id, 1, key, "hwp")

    conn =
      conn
      |> log_in_user(other)
      |> get("/documents/#{document.id}/rhwp-snapshots/1.hwp")

    assert response(conn, 404)
  end

  defp insert_snapshot!(document_id, revision, key, format) do
    %Record{}
    |> Record.changeset(%{
      document_id: document_id,
      revision: revision,
      r2_key: key,
      ir_r2_key: Contract.RhwpSnapshot.ir_key_for(key),
      format: format,
      content_type: Contract.RhwpSnapshot.content_type_for(format),
      projection: %{"sections" => [], "fields" => []}
    })
    |> Contract.Repo.insert!()
  end
end
