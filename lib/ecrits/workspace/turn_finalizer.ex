defmodule Ecrits.Workspace.TurnFinalizer do
  @moduledoc """
  Flushes the mounted projection work that may still be pending when an agent
  turn ends.

  `Ecrits.Workspace.Session` invokes this module after it has atomically claimed
  a terminal turn. Keeping the claim in the durable workspace coordinator means
  simultaneous LiveViews can all render the terminal event without flushing the
  same mounted projection more than once.

  It used to persist server-held documents too, enumerated from
  `Ecrits.Doc.Pool.dirty_docs/1`. That registry could hold no document and was
  deleted 2026-07-29 — the browser owns the model, so a document's unsaved edits
  live in the viewer, not in a server Editor this process could flush.
  """

  require Logger

  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.OpenDocs

  @type result :: %{
          saved: [String.t()],
          failed: [{String.t(), term()}],
          staged: %{
            committed: [String.t()],
            rejected: [{String.t(), term()}],
            pending: [{String.t(), term()}]
          },
          canonical: %{published: [String.t()], pending: [{String.t(), term()}]}
        }

  @spec run(String.t(), keyword()) :: result()
  def run(workspace_path, opts \\ []) when is_binary(workspace_path) and is_list(opts) do
    projection_opts =
      Keyword.take(opts, [
        :agent_id,
        :instance_id,
        :turn_id,
        :mounted?,
        :echo_fun,
        :remount?,
        :remount_fun
      ])

    # A staged ACP buffer must settle before its canonical projection is
    # published through a fresh mounted vnode.
    staged = flush_staged(workspace_path, projection_opts)
    canonical = flush_canonical(workspace_path, projection_opts)

    clear_durable_dirty_owners(workspace_path, projection_opts, staged, canonical)

    # `saved`/`failed` stay in the shape because `Session`'s summary matches on
    # them and its retry decision reads `failed`. Both are now always empty:
    # native saving was the Pool arm, and a document with unsaved edits is the
    # viewer's to persist.
    %{
      saved: [],
      failed: [],
      staged: staged,
      canonical: canonical
    }
  end

  # A document whose staged buffer or canonical value is still pending keeps its
  # dirty owner: the next attempt needs it to recognise the same turn.
  defp clear_durable_dirty_owners(workspace_path, opts, staged, canonical) do
    pending_names =
      staged.pending
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(Enum.map(canonical.pending, &elem(&1, 0)))
      |> MapSet.new()

    workspace_path
    |> OpenDocs.dirty_owner_entries(opts)
    |> Enum.each(fn entry ->
      unless MapSet.member?(pending_names, entry.name) do
        _ = OpenDocs.clear_dirty_owner(workspace_path, entry.name, entry)
      end
    end)
  end

  defp flush_staged(workspace_path, opts) do
    DocFs.flush_staged(workspace_path, opts)
  rescue
    error ->
      Logger.warning("turn finalizer: staged projection flush failed: #{inspect(error)}")
      %{committed: [], rejected: [], pending: [{workspace_path, error}]}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: staged projection flush exited: #{inspect(reason)}")
      %{committed: [], rejected: [], pending: [{workspace_path, reason}]}
  end

  defp flush_canonical(workspace_path, opts) do
    DocFs.flush_canonical(workspace_path, opts)
  rescue
    error ->
      Logger.warning("turn finalizer: canonical projection flush failed: #{inspect(error)}")
      %{published: [], pending: [{workspace_path, error}]}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: canonical projection flush exited: #{inspect(reason)}")
      %{published: [], pending: [{workspace_path, reason}]}
  end
end
