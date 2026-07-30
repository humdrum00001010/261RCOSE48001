defmodule Ecrits.Document.RhwpAdapter do
  @moduledoc """
  Adapter between rhwp's snapshot payload shape and local document sessions.

  It used to be the SYNC SEAM between two arms that could hold the same HWP
  file: `checkpoint/2`/`save/2` pushed the viewer's bytes into a server twin,
  and `open/3`/`load/1` preferred that twin's bytes when it was dirty. Both
  halves went with `Ecrits.Doc.Pool` (2026-07-29) — there is one arm now, so
  the disk bytes ARE the only server-side state a viewer can be handed.
  """

  alias Ecrits.Document
  alias Ecrits.Document.ByteSpool

  @spec open(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(workspace_root, relative_path, opts \\ []) do
    with {:ok, %Document{} = document} <- Document.open(workspace_root, relative_path, opts),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, bytes)}
    end
  end

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(document_id) when is_binary(document_id) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, bytes)}
    end
  end

  @spec checkpoint(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- decode_bytes(params),
         :ok <- verify_format(document, params),
         {:ok, saved_document, snapshot} <- Document.checkpoint(document, bytes, attrs(params)) do
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec save(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- decode_bytes(params),
         :ok <- verify_format(document, params),
         {:ok, saved_document, snapshot} <- Document.save(document, bytes, attrs(params)) do
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec save_replay(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save_replay(document_id, params) when is_binary(document_id) and is_map(params) do
    # Office journal replay needed the server engine that left with
    # `:libreofficex` (2026-07-26). The validation below still runs so a
    # malformed REQUEST gets its precise reason, but a well-formed one can only
    # report that the engine is gone — the save/sync tail was unreachable.
    with {:ok, %Document{} = document} <- Document.document(document_id),
         :ok <- verify_format(document, params),
         {:ok, _kind} <- office_kind(document.format),
         {:ok, _journal} <- replay_journal(params) do
      {:error, :office_replay_engine_removed}
    end
  end

  @spec record_mutation(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_mutation(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, _document} <- Document.document(document_id),
         {:ok, mutation} <- Document.record_mutation(document_id, params) do
      {:ok, %{ok: true, local: true, mutation: mutation}}
    end
  end

  defp load_response(%Document{} = document, bytes) do
    %{
      ok: true,
      local: true,
      document_id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      content_type: Document.content_type(document.format),
      byte_size: byte_size(bytes),
      sha256: Document.sha256(bytes),
      bytes: bytes
    }
  end

  defp save_response(%Document{} = document, snapshot) do
    %{
      ok: true,
      local: true,
      document_id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      snapshot: snapshot
    }
  end

  defp decode_bytes(params), do: ByteSpool.decode(params)

  defp replay_journal(params) do
    journal = param(params, :journal) || param(params, :replay_journal)

    case journal do
      [_ | _] = entries -> {:ok, entries}
      _other -> {:error, :missing_replay_journal}
    end
  end

  # Journal replay ran the browser's op journal through a SERVER-side LibreOffice
  # instance to produce saved bytes. That engine went with `:libreofficex` on
  # 2026-07-26. The browser already has the only working path — `officeSave()`
  # exports full bytes whenever the journal route is unavailable — so refuse here
  # and let the caller fall back instead of replaying into nothing.
  # See docs/plans/2026-07-26-doclang-engine-migration.md.
  defp verify_format(document, params) do
    case param(params, :format) do
      nil ->
        :ok

      format ->
        with {:ok, normalized} <- Document.normalize_format(to_string(format)),
             true <- normalized == document.format do
          :ok
        else
          false -> {:error, :format_mismatch}
          {:error, _} = error -> error
        end
    end
  end

  defp attrs(params) do
    %{
      request_id: param(params, :request_id),
      ir: param(params, :ir),
      context: param(params, :context)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp param(params, key) when is_map(params) and is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp office_kind("docx"), do: {:ok, :docx}
  defp office_kind("pptx"), do: {:ok, :pptx}
  defp office_kind("xlsx"), do: {:ok, :xlsx}
  defp office_kind(_format), do: {:error, :unsupported_replay_format}
end
