defmodule Contract.SourceDocumentsTest do
  use Contract.DataCase, async: false

  import Contract.AccountsFixtures
  import Ecto.Query

  alias Contract.IO.{R2Stub, UpstageStub}
  alias Contract.{Repo, SourceClaim, SourceDocument, SourceDocuments}

  setup do
    old_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      old_drivers
      |> Keyword.put(:r2, R2Stub)
      |> Keyword.put(:upstage, UpstageStub)
    )

    R2Stub.reset()
    UpstageStub.reset()

    on_exit(fn ->
      Application.put_env(:contract, :io_drivers, old_drivers)
      R2Stub.reset()
      UpstageStub.reset()
    end)

    :ok
  end

  test "create_from_upload stores a blob, creates a source document, parses regions, and proposes claims" do
    user = user_fixture()
    scope = Contract.Context.for_user(user)

    tmp = Path.join(System.tmp_dir!(), "source-upload-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "Effective Date: 2026-01-01\nParty A: Acme Corp\n")

    UpstageStub.set_response(%{
      elements: [
        %{
          "id" => "region-effective-date",
          "category" => "paragraph",
          "page" => 1,
          "coordinates" => [%{"x" => 0.1, "y" => 0.2}],
          "content" => %{"text" => "Effective Date: 2026-01-01"}
        }
      ],
      content: %{},
      raw: %{
        "claims" => [
          %{
            "region_id" => "region-effective-date",
            "kind" => "effective_date",
            "value" => "2026-01-01",
            "confidence" => 0.94,
            "anchors" => [%{"page" => 1, "bbox" => [%{"x" => 0.1, "y" => 0.2}]}],
            "rationale" => "Labelled effective date line"
          }
        ]
      }
    })

    upload = %{
      path: tmp,
      client_name: "counterparty.txt",
      client_type: "text/plain",
      client_size: File.stat!(tmp).size
    }

    assert {:ok, {%SourceDocument{} = source_document, [%SourceClaim{} = claim]}} =
             SourceDocuments.create_from_upload(scope, upload)

    assert source_document.owner_id == user.id
    assert source_document.status == "ready"
    assert source_document.original_filename == "counterparty.txt"

    assert [%{region_id: "region-effective-date", raw_text: "Effective Date: 2026-01-01"}] =
             source_document.regions

    assert claim.source_document_id == source_document.id
    assert claim.status == "proposed"
    assert claim.proposed_kind == "effective_date"
    assert claim.proposed_value == "2026-01-01"
    assert Decimal.equal?(claim.confidence, Decimal.new("0.94"))

    assert claim.proposed_structured["anchors"] == [
             %{"page" => 1, "bbox" => [%{"x" => 0.1, "y" => 0.2}]}
           ]

    assert Repo.get!(SourceDocument, source_document.id).owner_id == user.id
    assert Repo.get!(SourceClaim, claim.id).source_document_id == source_document.id

    assert Enum.any?(R2Stub.calls(), fn
             {:put, "uploads/" <> _, _, _} -> true
             _ -> false
           end)

    assert [{:parse, _bytes, _opts}] = UpstageStub.calls()
  end

  test "create_from_upload can use the deterministic source parser without calling live Upstage" do
    user = user_fixture()
    scope = Contract.Context.for_user(user)

    old_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(old_drivers, :upstage, Contract.IO.DeterministicParser)
    )

    on_exit(fn -> Application.put_env(:contract, :io_drivers, old_drivers) end)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "deterministic-source-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(tmp, "Effective Date: 2026-01-01\nParty A: Acme Corp\n")

    upload = %{
      path: tmp,
      client_name: "counterparty.txt",
      client_type: "text/plain",
      client_size: File.stat!(tmp).size
    }

    assert {:ok, {%SourceDocument{status: "ready"} = source_document, claims}} =
             SourceDocuments.create_from_upload(scope, upload)

    refute Repo.exists?(
             from sd in SourceDocument,
               where: sd.id == ^source_document.id and sd.status == "parsing"
           )

    assert Enum.map(claims, & &1.proposed_kind) == ["effective_date", "party_a"]
    assert Enum.map(claims, & &1.proposed_value) == ["2026-01-01", "Acme Corp"]
    assert UpstageStub.calls() == []
  end

  test "create_from_upload marks the source document failed when parsing fails" do
    user = user_fixture()
    scope = Contract.Context.for_user(user)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "failed-source-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(tmp, "not a parseable contract")

    upload = %{
      path: tmp,
      client_name: "bad.txt",
      client_type: "text/plain",
      client_size: File.stat!(tmp).size
    }

    reason = {:upstage_http, 400, %{"error" => %{"code" => "no_document"}}}
    UpstageStub.fail_next(reason)

    assert {:error, {:source_parse_failed, ^reason, %SourceDocument{} = source_document}} =
             SourceDocuments.create_from_upload(scope, upload)

    assert Repo.get!(SourceDocument, source_document.id).status == "failed"

    refute Repo.exists?(
             from sd in SourceDocument,
               where: sd.id == ^source_document.id and sd.status == "parsing"
           )

    assert Repo.aggregate(SourceClaim, :count) == 0
  end

  test "owner cannot fetch another owner source document" do
    owner = user_fixture()
    other = user_fixture()

    {:ok, source_document} =
      %SourceDocument{}
      |> SourceDocument.changeset(%{
        owner_id: owner.id,
        blob_ref_id: Ecto.UUID.generate(),
        status: "ready"
      })
      |> Repo.insert()

    assert {:ok, %SourceDocument{id: id}} =
             SourceDocuments.get(Contract.Context.for_user(owner), source_document.id)

    assert id == source_document.id
    assert {:error, :forbidden} = SourceDocuments.get(Contract.Context.for_user(other), id)
  end
end
