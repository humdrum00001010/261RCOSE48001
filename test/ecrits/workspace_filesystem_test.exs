defmodule Ecrits.WorkspaceFilesystemTest do
  use ExUnit.Case, async: false

  alias Ecrits.Workspace

  test "workspace boundary rejects absolute, traversal, metadata, and symlink paths" do
    root = tmp_root()

    outside =
      Path.join(System.tmp_dir!(), "ecrits-outside-#{System.unique_integer([:positive])}")

    link = Path.join(root, "linked")

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    on_exit(fn -> File.rm(outside) end)

    assert {:ok, workspace} = Workspace.init(root)
    stop_workspace_on_exit(workspace)

    assert {:error, :absolute_path} = Workspace.native_path(workspace, outside)
    assert {:error, :path_traversal} = Workspace.native_path(workspace, "../outside.txt")
    assert {:error, :metadata_path} = Workspace.native_path(workspace, ".ecrits/config.json")

    assert :ok = File.ln_s(outside, link)
    assert {:error, :eacces} = Workspace.native_path(workspace, "linked")
    assert {:error, :eacces} = Workspace.read_file(workspace, "linked")
  end

  test "real workspace writes atomically and lists without .ecrits metadata" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    stop_workspace_on_exit(workspace)
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "first")
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "second")

    assert {:ok, "second"} = Workspace.read_file(workspace, "docs/a.txt")

    assert {:ok, root_entries} = Workspace.list(workspace)
    assert Enum.map(root_entries, & &1.name) == ["docs"]
    refute File.exists?(Path.join(root, ".ecrits"))

    assert {:ok, doc_entries} = Workspace.list(workspace, "docs")
    assert [%{name: "a.txt", path: "docs/a.txt", type: :file}] = doc_entries

    doc_dir_names = File.ls!(Path.join(root, "docs"))
    refute Enum.any?(doc_dir_names, &String.contains?(&1, ".tmp-"))
  end

  test "fs lists directories first, then files, sorted by name" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    stop_workspace_on_exit(workspace)
    assert :ok = Workspace.write_file(workspace, "z-file.hwp", "z")
    assert :ok = Workspace.write_file(workspace, "A-file.hwp", "a")
    assert :ok = Workspace.write_file(workspace, "docs/zeta.hwp", "zeta")
    assert :ok = Workspace.write_file(workspace, "Alpha/nested.hwp", "alpha")
    assert :ok = Workspace.write_file(workspace, "beta/nested.hwp", "beta")

    assert {:ok, root_entries} = Workspace.list(workspace)

    assert Enum.map(root_entries, &{&1.type, &1.name}) == [
             {:directory, "Alpha"},
             {:directory, "beta"},
             {:directory, "docs"},
             {:file, "A-file.hwp"},
             {:file, "z-file.hwp"}
           ]
  end

  test "workspace can use an injected in-memory Exfuse filesystem" do
    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Memory, files: %{})
    on_exit(fn -> if Process.alive?(fs), do: Exfuse.stop_fs(fs) end)

    workspace = Workspace.from_fs("/memory", fs)

    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "hello")
    assert {:ok, "hello"} = Workspace.read_file(workspace, "docs/a.txt")

    assert {:ok, [%{name: "docs", path: "docs", type: :directory}]} =
             Workspace.list(workspace)

    assert {:error, :native_path_unavailable} = Workspace.native_path(workspace, "docs/a.txt")
  end

  test "workspace roots reuse one shared real filesystem" do
    root = tmp_root()

    assert {:ok, first} = Workspace.init(root)
    stop_workspace_on_exit(first)
    assert {:ok, second} = Workspace.init(root)
    assert first.fs == second.fs
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "ecrits-fs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp stop_workspace_on_exit(workspace) do
    on_exit(fn ->
      if Process.alive?(workspace.fs), do: Exfuse.stop_fs(workspace.fs)
    end)
  end
end
