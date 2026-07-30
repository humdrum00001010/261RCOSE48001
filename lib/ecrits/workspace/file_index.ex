defmodule Ecrits.Workspace.FileIndex do
  @moduledoc false

  @default_limit 200
  @max_depth 8

  @text_extensions MapSet.new(
                     ~w(.xml .jsonl .json .md .txt .csv .tsv .yaml .yml .toml .ex .exs .heex .js .ts .css .html)
                   )
  @picture_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .tif .tiff))
  @office_extensions MapSet.new(~w(.hwp .hwpx .doc .docx .ppt .pptx .xls .xlsx .pdf))

  # A document listing is a whole mount namespace, not a preview payload, so it
  # gets its own ceiling: truncating at 200 would silently hide a document that
  # HAS a live viewer and can be served.
  @document_limit 2_000

  alias Ecrits.Doc.Projection
  alias Ecrits.Workspace

  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(root, opts \\ []) when is_binary(root) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@default_limit)
    scan(root, limit, &indexed_file/2)
  end

  @doc """
  Every document under `root` that `Ecrits.Doc.Projection` can render, as
  `%{"path" => workspace_relative, "absolute_path" => native}`.

  Separate from `list/2` rather than a kind added to it: `list/2` is the
  agent-facing "code-editor evidence" payload and deliberately carries text +
  pictures only. The predicate here is `Projection.supported?/1`
  and NOT `office_path?/1`, whose set is wider than anything that can project
  (`.doc .ppt .xls .pdf` have no adapter), so a mount built on the latter would
  list entries that can only fail.

  The traversal is shared with `list/2` on purpose — its rules are exactly a
  mount's: hidden entries are skipped, which is what keeps `.ecrits` (the mount
  point itself) out of its own listing, and symlinks are skipped, so no entry
  escapes the workspace.

  Every read goes through `Exfuse.Fs.Real`, whose list/stat path is `:prim_file`,
  so the VFS handler that calls this stays off the global `:file_server` — with
  one exception worth knowing: `Exfuse.Fs.Real.exfuse_init/1` runs
  `File.mkdir_p(root)`, so the FIRST `Workspace.init/1` for a root does make one
  `:file_server` call, on the workspace root and never on the mount inside it.
  """
  @spec list_documents(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_documents(root, opts \\ []) when is_binary(root) do
    limit = opts |> Keyword.get(:limit, @document_limit) |> max(1) |> min(@document_limit)
    scan(root, limit, &document_file/2)
  end

  defp scan(root, limit, classify) do
    root = Path.expand(root)

    with {:ok, workspace} <- Workspace.init(root) do
      case walk(workspace, ".", 0, limit, classify) do
        {:ok, files, _remaining} -> {:ok, files}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec text_path?(String.t()) :: boolean()
  def text_path?(path), do: extension_in?(path, @text_extensions)

  @spec picture_path?(String.t()) :: boolean()
  def picture_path?(path), do: extension_in?(path, @picture_extensions)

  @spec office_path?(String.t()) :: boolean()
  def office_path?(path), do: extension_in?(path, @office_extensions)

  defp walk(_root, _relative, _depth, 0, _classify), do: {:ok, [], 0}

  defp walk(_root, _relative, depth, remaining, _classify) when depth > @max_depth,
    do: {:ok, [], remaining}

  defp walk(workspace, relative, depth, remaining, classify) do
    with {:ok, entries} <- Workspace.list(workspace, relative) do
      Enum.reduce_while(entries, {:ok, [], remaining}, fn entry, {:ok, files, left} ->
        cond do
          left == 0 ->
            {:halt, {:ok, files, 0}}

          hidden_entry?(entry) or entry.type in [:symlink, :other] ->
            {:cont, {:ok, files, left}}

          entry.type == :directory ->
            case walk(workspace, entry.path, depth + 1, left, classify) do
              {:ok, nested, next_left} -> {:cont, {:ok, files ++ nested, next_left}}
              {:error, _reason} -> {:cont, {:ok, files, left}}
            end

          entry.type == :file ->
            case classify.(workspace, entry.path) do
              {:ok, file} -> {:cont, {:ok, files ++ [file], left - 1}}
              :skip -> {:cont, {:ok, files, left}}
            end
        end
      end)
    end
  end

  defp indexed_file(workspace, relative) do
    kind =
      cond do
        text_path?(relative) -> "text"
        picture_path?(relative) -> "picture"
        true -> nil
      end

    case {kind, Workspace.stat(workspace, relative), Workspace.native_path(workspace, relative)} do
      {kind, {:ok, %Exfuse.Fs.Stat{type: :file}}, {:ok, absolute}} when is_binary(kind) ->
        {:ok, %{"path" => relative, "absolute_path" => absolute, "kind" => kind}}

      _other ->
        :skip
    end
  end

  # `native_path/2` is what rejects a symlinked leaf, so the absolute path handed
  # back always names a file inside the workspace.
  defp document_file(workspace, relative) do
    with true <- Projection.supported?(relative),
         {:ok, %Exfuse.Fs.Stat{type: :file}} <- Workspace.stat(workspace, relative),
         {:ok, absolute} <- Workspace.native_path(workspace, relative) do
      {:ok, %{"path" => relative, "absolute_path" => absolute}}
    else
      _other -> :skip
    end
  end

  defp hidden_entry?(%{path: path}) do
    not String.valid?(path) or
      path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp extension_in?(path, extensions) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> then(&MapSet.member?(extensions, &1))
  end

  defp extension_in?(_path, _extensions), do: false
end
