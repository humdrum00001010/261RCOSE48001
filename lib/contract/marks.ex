defmodule Contract.Marks do
  @moduledoc """
  Document-owner-scoped durable marks for evidence attachments.
  """

  import Ecto.Query

  alias Contract.{Context, Documents, EvidenceSnapshot, EvidenceSnapshots, Mark, Repo}

  @spec get_evidence_snapshot(Context.t(), Ecto.UUID.t()) ::
          {:ok, EvidenceSnapshot.t()} | {:error, :not_found | :forbidden}
  def get_evidence_snapshot(%Context{} = ctx, id), do: EvidenceSnapshots.get(ctx, id)
  def get_evidence_snapshot(_ctx, _id), do: {:error, :forbidden}

  @spec attach_evidence(Context.t(), Ecto.UUID.t(), map()) ::
          {:ok, Mark.t()} | {:error, term()}
  def attach_evidence(%Context{} = ctx, evidence_snapshot_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    document_id = Map.get(attrs, "document_id")

    with {:ok, evidence} <- EvidenceSnapshots.get(ctx, evidence_snapshot_id),
         {:ok, document} <- Documents.get(ctx, document_id),
         :ok <- evidence_matches_document(evidence, document.id) do
      mark_attrs = %{
        "document_id" => document.id,
        "evidence_snapshot_id" => evidence.id,
        "field_path" => Map.get(attrs, "field_path", []),
        "change_id" => Map.get(attrs, "change_id"),
        "type" => Map.get(attrs, "type", "evidence"),
        "status" => Map.get(attrs, "status", "attached"),
        "metadata" => Map.get(attrs, "metadata", %{})
      }

      %Mark{}
      |> Mark.changeset(mark_attrs)
      |> Repo.insert()
    end
  end

  def attach_evidence(_ctx, _evidence_snapshot_id, _attrs), do: {:error, :forbidden}

  @spec list_for_document(Context.t(), Ecto.UUID.t()) :: [Mark.t()]
  def list_for_document(%Context{} = ctx, document_id) when is_binary(document_id) do
    with {:ok, doc} <- Documents.get(ctx, document_id) do
      from(m in Mark,
        where: m.document_id == ^doc.id,
        order_by: [desc: m.inserted_at]
      )
      |> Repo.all()
    else
      _ -> []
    end
  end

  def list_for_document(_ctx, _document_id), do: []

  defp evidence_matches_document(%EvidenceSnapshot{document_id: nil}, _document_id), do: :ok

  defp evidence_matches_document(%EvidenceSnapshot{document_id: document_id}, document_id),
    do: :ok

  defp evidence_matches_document(%EvidenceSnapshot{}, _document_id), do: {:error, :forbidden}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
