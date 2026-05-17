defmodule Contract.Exports do
  @moduledoc """
  Context for persisted export requests and delivery metadata.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents.Document
  alias Contract.Export
  alias Contract.Repo

  @type result(t) :: {:ok, t} | {:error, term()}

  @doc "Create a queued export request after the caller has authorized the document."
  @spec create_request(Context.t() | nil, Ecto.UUID.t(), atom(), Ecto.UUID.t() | nil) ::
          result(Export.t())
  def create_request(_ctx, document_id, format, requester_id)
      when is_binary(document_id) and is_atom(format) do
    %Export{}
    |> Export.changeset(%{
      document_id: document_id,
      requester_id: requester_id,
      format: format,
      status: :queued,
      progress: 0
    })
    |> Repo.insert()
    |> normalize_url()
  end

  @doc "Fetch any export row by id without applying caller ACL. Worker-only."
  @spec get(Ecto.UUID.t()) :: result(Export.t())
  def get(id) when is_binary(id) do
    case Repo.get(Export, id) do
      nil -> {:error, :not_found}
      %Export{} = export -> {:ok, with_legacy_url(export)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc "Fetch a ready export that belongs to the current user."
  @spec get_ready_for_download(Context.t() | nil, Ecto.UUID.t()) :: result(Export.t())
  def get_ready_for_download(%Context{user: %{id: user_id}}, export_id)
      when is_binary(export_id) do
    query =
      from e in Export,
        join: d in Document,
        on: d.id == e.document_id,
        where: e.id == ^export_id and d.owner_id == ^user_id and e.status == :ready,
        select: e

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Export{} = export -> {:ok, with_legacy_url(export)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get_ready_for_download(_scope, _export_id), do: {:error, :not_found}

  @spec mark_running(Ecto.UUID.t()) :: result(Export.t())
  def mark_running(export_id) do
    update_status(export_id, %{status: :running, progress: 10, error: %{}})
  end

  @spec mark_ready(Ecto.UUID.t(), map()) :: result(Export.t())
  def mark_ready(export_id, attrs) do
    attrs =
      attrs
      |> Map.put(:status, :ready)
      |> Map.put(:progress, 100)
      |> Map.put_new(:error, %{})

    update_status(export_id, attrs)
  end

  @spec mark_failed(Ecto.UUID.t(), term()) :: result(Export.t())
  def mark_failed(export_id, reason) do
    update_status(export_id, %{
      status: :failed,
      progress: 100,
      error: %{reason: inspect(reason)}
    })
  end

  defp update_status(export_id, attrs) do
    with {:ok, %Export{} = export} <- get(export_id) do
      export
      |> Export.changeset(attrs)
      |> Repo.update()
      |> normalize_url()
    end
  end

  defp normalize_url({:ok, %Export{} = export}), do: {:ok, with_legacy_url(export)}
  defp normalize_url(other), do: other

  def with_legacy_url(%Export{} = export), do: %{export | url: export.download_url}
end
