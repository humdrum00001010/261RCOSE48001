defmodule Ecrits.Workspace do
  @moduledoc """
  Workspace-domain handle for an Exfuse filesystem.

  Generic filesystem operations and subscriptions belong to Exfuse. This
  module only binds one filesystem PID to a workspace root and translates the
  workspace's relative-path contract for callers and native document engines.
  """

  import Ecrits.Guards

  alias Exfuse.Fs
  alias Exfuse.Fs.Entry

  @metadata_dir ".ecrits"

  defstruct [:root, :fs]

  @type t :: %__MODULE__{root: String.t(), fs: pid()}
  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: :directory | :file | :symlink | :other,
          size: non_neg_integer()
        }

  @doc """
  Ensure a shared real filesystem for a workspace root.
  """
  @spec init(String.t()) :: {:ok, t()} | {:error, term()}
  def init(root) when is_present(root) do
    root = Path.expand(root)

    with {:ok, fs} <-
           Exfuse.ensure_fs(
             Exfuse.Fs.Real,
             [root: root, exclude: [@metadata_dir]],
             key: {__MODULE__, root}
           ) do
      {:ok, from_fs(root, fs)}
    end
  end

  def init(_root), do: {:error, :invalid_workspace_root}

  @doc "Bind an existing Exfuse filesystem, including `Exfuse.Fs.Memory`, to a workspace."
  @spec from_fs(String.t(), pid()) :: t()
  def from_fs(root, fs) when is_binary(root) and is_pid(fs),
    do: %__MODULE__{root: Path.expand(root), fs: fs}

  @spec list(t() | String.t(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(workspace_or_root, relative \\ ".")

  def list(%__MODULE__{fs: fs}, relative) do
    with {:ok, logical} <- logical_path(relative),
         {:ok, entries} <- Fs.list(fs, logical) do
      {:ok, entries |> Enum.map(&workspace_entry/1) |> Enum.sort_by(&entry_sort_key/1)}
    end
  end

  def list(root, relative) when is_binary(root) do
    with {:ok, workspace} <- init(root), do: list(workspace, relative)
  end

  @spec read_file(t() | String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{fs: fs}, relative) do
    with {:ok, logical} <- logical_path(relative), do: Fs.read(fs, logical)
  end

  def read_file(root, relative) when is_binary(root) do
    with {:ok, workspace} <- init(root), do: read_file(workspace, relative)
  end

  @spec stat(t() | String.t(), String.t()) :: {:ok, Exfuse.Fs.Stat.t()} | {:error, term()}
  def stat(%__MODULE__{fs: fs}, relative) do
    with {:ok, logical} <- logical_path(relative), do: Fs.stat(fs, logical)
  end

  def stat(root, relative) when is_binary(root) do
    with {:ok, workspace} <- init(root), do: stat(workspace, relative)
  end

  @spec write_file(t() | String.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(workspace_or_root, relative, contents, opts \\ [])

  def write_file(%__MODULE__{fs: fs}, relative, contents, opts) when is_binary(contents) do
    with {:ok, logical} <- logical_path(relative), do: Fs.write(fs, logical, contents, opts)
  end

  def write_file(root, relative, contents, opts) when is_binary(root),
    do: with({:ok, workspace} <- init(root), do: write_file(workspace, relative, contents, opts))

  @doc "Validate and canonicalize a workspace-relative path."
  @spec normalize_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_path(path) do
    with {:ok, logical} <- logical_path(path) do
      case logical do
        "/" -> {:ok, "."}
        "/" <> relative -> {:ok, relative}
      end
    end
  end

  @doc "Resolve an existing real-workspace path for a native document engine."
  @spec native_path(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def native_path(%__MODULE__{} = workspace, relative) do
    with {:ok, path} <- reference_path(workspace, relative),
         {:ok, logical} <- logical_path(relative),
         {:ok, stat} <- Fs.stat(workspace.fs, logical),
         :ok <- reject_symlink(stat) do
      {:ok, path}
    end
  end

  @doc """
  Resolve a validated real-workspace path without requiring the leaf to exist.

  This is for durable references whose bytes live elsewhere, such as a persisted
  preview snapshot replayed after the original workspace file was deleted.
  """
  @spec reference_path(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def reference_path(%__MODULE__{} = workspace, relative) do
    with :ok <- real_filesystem(workspace.fs),
         {:ok, logical} <- logical_path(relative) do
      {:ok, host_path(workspace.root, logical)}
    end
  end

  @doc "Return a workspace-relative path for an absolute path inside the root."
  @spec relative_path(t() | String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def relative_path(%__MODULE__{root: root}, path), do: relative_path(root, path)

  def relative_path(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    path = Path.expand(path)

    cond do
      path == root ->
        {:ok, "."}

      String.starts_with?(path, root <> "/") ->
        normalize_path(Path.relative_to(path, root))

      true ->
        {:error, :outside_workspace}
    end
  end

  def relative_path(_root, _path), do: {:error, :invalid_path}

  @doc "Whether an absolute path is the workspace root or one of its descendants."
  @spec contains?(t() | String.t(), String.t()) :: boolean()
  def contains?(workspace_or_root, path),
    do: match?({:ok, _relative}, relative_path(workspace_or_root, path))

  defp logical_path("."), do: {:ok, "/"}

  defp logical_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :empty_path}
      Path.type(path) == :absolute -> {:error, :absolute_path}
      true -> canonical_logical_path(path)
    end
  end

  defp logical_path(_path), do: {:error, :invalid_path}

  defp canonical_logical_path(path) do
    with {:ok, logical} <- Exfuse.Fs.Path.canonical(path),
         :ok <- reject_metadata(logical) do
      {:ok, logical}
    end
  end

  defp reject_metadata(logical) do
    if logical |> String.split("/", trim: true) |> Enum.member?(@metadata_dir),
      do: {:error, :metadata_path},
      else: :ok
  end

  defp real_filesystem(fs) do
    case Exfuse.Fs.Supervisor.status(fs) do
      %{module: Exfuse.Fs.Real} -> :ok
      _status -> {:error, :native_path_unavailable}
    end
  catch
    :exit, _reason -> {:error, :filesystem_stopped}
  end

  defp reject_symlink(%Exfuse.Fs.Stat{type: :symlink}), do: {:error, :eacces}
  defp reject_symlink(%Exfuse.Fs.Stat{}), do: :ok

  defp host_path(root, "/"), do: root
  defp host_path(root, "/" <> relative), do: Path.join(root, relative)

  defp workspace_entry(%Entry{} = entry) do
    %{
      name: entry.name,
      path: String.trim_leading(entry.path, "/"),
      type: entry.type,
      size: entry.size
    }
  end

  defp entry_sort_key(%{name: name, type: type}) do
    {entry_type_rank(type), String.downcase(name), name}
  end

  defp entry_type_rank(:directory), do: 0
  defp entry_type_rank(:file), do: 1
  defp entry_type_rank(:symlink), do: 2
  defp entry_type_rank(_type), do: 3
end
