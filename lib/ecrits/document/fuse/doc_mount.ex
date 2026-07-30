defmodule Ecrits.Fuse.DocMount do
  @moduledoc """
  Stateless facade over `Exfuse` for the per-workspace document VFS mount.

  One mount per workspace, living at `<workspace_root>/.ecrits`, serving
  `Ecrits.Fuse.DocFs` over the workspace root. There is NO GenServer here — this
  module only holds the `ensure`/`teardown` bookkeeping; `exfuse`'s own
  `Exfuse.MountSup` owns the port processes.

  `ensure/1` and `teardown/1` are defensive: they run from the workspace
  `Ecrits.Workspace.Session` GenServer (and a LiveView Task), so a mount failure
  (missing native backend, VFS backend error) must NEVER crash the caller. Both
  rescue/catch and log via `Logger`.

  Mount mechanics live in `exfuse`: per-point exclusive servers, dead-mount
  healing, busy retry, serving verification with rollback, and idempotent
  force-unmount. This module only decides WHEN to (re)mount. Reuse requires both
  a serving OS mount and a matching mount owned by this BEAM in `Exfuse.list/0`:
  FSKit can leave an old mount serving cached data after its owning BEAM exits,
  and that orphan must be detached and remounted instead of reported `:already`.

  Gated by `enabled?/0`: the `:doc_vfs` config flag (default ON) and a usable
  native backend. The backend is determined by the OS alone — macOS mounts
  through FSKit and every other Unix through the FUSE/libfuse Rust port.
  There is no macFUSE path: when FSKit is not mountable the status explains
  why instead of falling back. See
  `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  require Logger

  @fskit_extension_id "org.exfuse.fskit.extension"
  @fskit_settings_url "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"

  @mount_dirname ".ecrits"

  @doc "The mount's directory name inside a workspace, for agent-facing copy."
  @spec mount_dirname() :: String.t()
  def mount_dirname, do: @mount_dirname

  @doc "The mount point for a workspace root: `<root>/.ecrits` (root realpathed)."
  @spec mount_point(String.t()) :: String.t()
  def mount_point(root), do: Path.join(canonical_root(root), @mount_dirname)

  @doc """
  The flat mount entry name for a workspace-relative document path.

  The doc VFS namespace has ONE level, so a nested path is folded into a single
  segment by percent-encoding `%` (first, or the decode is ambiguous) then `/`.
  Shared between the mount's listing, its name resolution and the staging keys
  because all of them must agree byte for byte — a listed name spelled
  differently anywhere else cannot be stat'ed.

  A root-level path is passed through unencoded, preserving the names already in
  `OpenDocs` — UNLESS it already spells one of the two markers. That exception is
  what makes `source_name/1` a true inverse: passing root `a%2Fb.hwp` through
  verbatim gave it the same entry as nested `a/b.hwp`, and one of the two could
  then never be decoded back. Encoding the ambiguous root names (only those
  containing a literal `%25` or `%2F`) removes the collision instead of leaving
  `Doc.Tools` to hash around it, and every ordinary name — including `100%.hwp` —
  still mounts unchanged.
  """
  @spec mount_name(String.t()) :: String.t()
  def mount_name(relative) when is_binary(relative) do
    if Path.dirname(relative) == "." and not String.contains?(relative, ["%25", "%2F"]) do
      relative
    else
      relative
      |> String.replace("%", "%25")
      |> String.replace("/", "%2F")
    end
  end

  @doc """
  Populate the projection cache for the document `document_id` names under `root`.

  `DocFs.readdir` sizes its entries from that cache. An entry it cannot size
  would have to be advertised as 0, and a vnode that observes 0 is stuck at
  "empty" permanently — so the cache must be warm before the first listing.
  Viewer attach is exactly that moment: it is when the document starts being
  listed, and the browser is loading it anyway.

  Unlinked and best effort. Nothing waits on it, and a viewer that cannot project
  must not break the attach.
  """
  @spec warm_projection(String.t(), String.t()) :: :ok
  def warm_projection(root, document_id) when is_binary(root) and is_binary(document_id) do
    Task.Supervisor.start_child(Ecrits.Doc.PreviewTaskSupervisor, fn ->
      root = canonical_root(root)

      with {:ok, documents} <- Ecrits.Workspace.FileIndex.list_documents(root),
           %{"absolute_path" => abs, "path" => rel} <-
             Enum.find(documents, &document_matches?(&1, document_id)) do
        Ecrits.Fuse.DocFs.warm(root, mount_name(rel), abs)
      end
    end)

    :ok
  end

  def warm_projection(_root, _document_id), do: :ok

  defp document_matches?(%{"absolute_path" => abs}, document_id) do
    match?({:ok, ^document_id}, Ecrits.Doc.Projection.document_id(abs))
  end

  defp document_matches?(_document, _document_id), do: false

  @doc """
  The workspace-relative path a `mount_name/1` entry was folded from.

  `mount_name(rel) |> source_name() == rel` for every relative path (the property
  test in `test/ecrits/fuse/doc_fs_test.exs` pins it): encoded output always
  contains a marker and pass-through output never does, so the two cases stay
  disjoint and decoding a pass-through name is a no-op.

  `%2F` must be decoded BEFORE `%25` — the other order turns the encoded `%252F`
  (a filename that really contains `%2F`) into a path separator. Within encoded
  output every `%` begins a marker, so no `%25`/`%2F` substring survives the
  first pass that was not written by the encoder.

  Not `URI.decode/1`: that would also decode escapes the encoder never emits, so
  a document named `%41.hwp` would resolve under a name that is not its own.
  """
  @spec source_name(String.t()) :: String.t()
  def source_name(name) when is_binary(name) do
    name
    |> String.replace("%2F", "/")
    |> String.replace("%25", "%")
  end

  @doc false
  @spec canonical_root(String.t()) :: String.t()
  def canonical_root(root) when is_binary(root) do
    root = Path.expand(root)
    private_tmp_path(root) || root
  end

  @doc """
  Whether the doc VFS can be mounted on this machine: `:doc_vfs` config not
  disabled (default ON) and the selected backend has the local executables and
  OS extension enablement it needs.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    status().enabled?
  end

  @doc """
  Full local availability status for the selected doc VFS backend.

  `enabled?/0` intentionally stays boolean for fast gates, while this function is
  used by tools/prompts to explain why the selected doc VFS backend is not mountable.
  """
  @spec status() :: %{
          enabled?: boolean(),
          backend: :fskit | :fuse,
          reason: atom() | nil,
          message: String.t() | nil,
          settings_url: String.t() | nil
        }
  def status do
    if config_enabled?() do
      backend_status(backend())
    else
      unavailable(backend(), :config_disabled)
    end
  end

  @doc false
  @spec status_message(map()) :: String.t()
  def status_message(%{reason: nil, backend: backend}),
    do: "Doc VFS #{backend} backend is available."

  def status_message(%{reason: :config_disabled}),
    do: "Doc VFS is disabled by :doc_vfs configuration."

  def status_message(%{reason: :fskit_requires_macos}),
    do: "FSKit backend is only available on macOS."

  def status_message(%{reason: :missing_mount}),
    do: "FSKit backend requires the macOS mount executable."

  def status_message(%{reason: :fskit_extension_not_registered}),
    do:
      "FSKit extension #{@fskit_extension_id} is not registered. Run exfuse.fskit.install first."

  def status_message(%{reason: :fskit_extension_disabled}),
    do:
      "FSKit extension #{@fskit_extension_id} is registered but disabled. Enable exfuse in System Settings > General > Login Items & Extensions > File System Extensions."

  def status_message(%{reason: :fskit_extension_unsigned}),
    do:
      "FSKit extension #{@fskit_extension_id} is registered but ad-hoc signed with the restricted FSKit entitlement; sign it with a trusted code-signing identity and reinstall it."

  def status_message(%{reason: :fuse_port_unavailable}),
    do: "FUSE backend port executable is unavailable."

  def status_message(%{reason: reason}), do: "Doc VFS unavailable: #{inspect(reason)}."

  @doc false
  @spec settings_url() :: String.t()
  def settings_url, do: @fskit_settings_url

  @doc "Whether this runtime owns the workspace mount and it is serving requests."
  @spec mounted?(String.t()) :: boolean()
  def mounted?(root) do
    point = mount_point(root)

    cond do
      MapSet.member?(virtual_mounts(), canonical_root(root)) ->
        true

      true ->
        case mounts_at(point) do
          [] -> false
          mounts -> reusable_mount?(point, mounts, Exfuse.serving?(point))
        end
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc false
  @spec reusable_mount?(String.t(), list(), boolean()) :: boolean()
  def reusable_mount?(point, mounts, serving?)
      when is_binary(point) and is_list(mounts) and is_boolean(serving?) do
    point = Path.expand(point)

    serving? and
      Enum.any?(mounts, fn
        {mount, %{mount_point: owned_point}} when is_pid(mount) and is_binary(owned_point) ->
          Process.alive?(mount) and Path.expand(owned_point) == point

        _other ->
          false
      end)
  end

  @doc """
  Idempotently mount the doc VFS for a workspace root.

  `:disabled` when `enabled?/0` is false, `{:ok, :already}` when already mounted,
  `{:ok, :mounted}` on a fresh mount, or `{:error, reason}`. Never raises.
  """
  @spec ensure(String.t()) :: :disabled | {:ok, :already | :mounted} | {:error, term()}
  def ensure(root) do
    root = canonical_root(root)

    with_mount_lock(fn ->
      status = status()
      _ = remove_legacy_mount(root)

      cond do
        not status.enabled? -> :disabled
        virtual_mounting?() -> put_virtual_mount(root)
        mounted?(root) -> {:ok, :already}
        true -> do_mount(root, status.backend)
      end
    end)
  rescue
    error ->
      Logger.error("[DocMount] ensure crashed for #{inspect(root)}: #{inspect(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("[DocMount] ensure crashed for #{inspect(root)}: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @doc "Remount the workspace doc VFS so FSKit sees a changed open-document set."
  @spec refresh(String.t(), keyword()) :: :disabled | {:ok, :mounted} | {:error, term()}
  def refresh(root, opts \\ []) when is_list(opts) do
    root = canonical_root(root)

    with_mount_lock(fn ->
      status = status()
      _ = remove_legacy_mount(root)

      # A remount is the explicit "start fresh" signal, and `DocFs.projected_bytes/2`
      # prefers the committed cache over re-projecting — so without this the mount
      # keeps serving the OLD projection shape (e.g. still carrying `<table>` blocks
      # after `Projection.editable_nodes/2` began dropping them) while `coverage`
      # reports the new one. Every edit then fails as a structural change with no
      # visible cause.
      _ = Ecrits.Fuse.OpenDocs.clear_cached_projections(root)

      cond do
        not status.enabled? ->
          :disabled

        virtual_mounting?() ->
          _ = put_virtual_mount(root)
          {:ok, :mounted}

        true ->
          :ok = unmount_point(mount_point(root))
          :ok = run_before_mount(Keyword.get(opts, :before_mount))
          do_mount(root, status.backend)
      end
    end)
  rescue
    error ->
      Logger.error("[DocMount] refresh crashed for #{inspect(root)}: #{inspect(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("[DocMount] refresh crashed for #{inspect(root)}: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp run_before_mount(nil), do: :ok
  defp run_before_mount(fun) when is_function(fun, 0), do: fun.()

  @doc """
  Unmount the workspace's doc VFS. Treats absent/unmounted as success. Never
  raises. `Exfuse.unmount/1` handles the native detach; the workspace filesystem
  runtime is stopped after its mount process is gone.
  """
  @spec teardown(String.t()) :: :ok | {:error, term()}
  def teardown(root) do
    root = canonical_root(root)
    point = mount_point(root)

    with_mount_lock(fn ->
      delete_virtual_mount(root)
      :ok = unmount_point(point)
      :ok = Ecrits.Fuse.OpenDocs.close_root(root)
      remove_legacy_mount(root)
    end)
  rescue
    error ->
      Logger.error("[DocMount] teardown crashed for #{inspect(root)}: #{inspect(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("[DocMount] teardown crashed for #{inspect(root)}: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  # ── helpers ───────────────────────────────────────────────────────

  # Several LiveViews or tests can ask for the same workspace mount concurrently.
  # Serialize mount attempts so half-started FSKit/exfuse lifecycles do not race
  # each other while we decide whether the existing mount can be shared.
  defp with_mount_lock(fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, :mount}, fun)
  end

  defp do_mount(root, backend) do
    root = canonical_root(root)
    point = mount_point(root)
    # Clear any lingering/half-stopped server first; exfuse owns the rest of
    # the mechanics (exclusivity, dead-mount healing, busy retry, and the
    # `verify: :serving` gate that rolls back a mount that never serves).
    _ = unmount_point(point)

    case Exfuse.start_fs(Ecrits.Fuse.DocFs, %{root: root}) do
      {:ok, fs} ->
        mount_fs(fs, point, backend)

      {:error, reason} ->
        mount_error(point, reason)
    end
  end

  defp mount_fs(fs, point, backend) do
    case Exfuse.mount(fs, point, backend: backend, verify: :serving) do
      {:ok, _mount} ->
        Logger.info("[DocMount] mounted doc VFS at #{point}")
        {:ok, :mounted}

      {:error, {:already_mounted, _pid}} ->
        Exfuse.stop_fs(fs)
        {:ok, :already}

      {:error, reason} ->
        Exfuse.stop_fs(fs)
        mount_error(point, reason)
    end
  end

  defp mount_error(point, reason) do
    # Exfuse rolled the mount back; do not leave an empty mount-point directory.
    # `rmdir` refuses non-empty paths, so user content is never removed.
    clean_empty_mount_point(point)
    Logger.error("[DocMount] mount failed at #{point}: #{inspect(reason)}")
    {:error, reason}
  end

  defp unmount_point(point) do
    filesystems =
      point
      |> mounts_at()
      |> Enum.map(fn {_mount, %{fs: fs}} -> fs end)
      |> Enum.uniq()

    # The path form also detaches a dead FSKit/FUSE mount whose VM is gone and
    # therefore cannot appear in `Exfuse.list/0`.
    :ok = Exfuse.unmount(point)
    Enum.each(filesystems, &Exfuse.stop_fs/1)

    :ok
  end

  defp mounts_at(point) do
    Enum.filter(Exfuse.list(), fn {_mount, status} -> status.mount_point == point end)
  end

  defp remove_legacy_mount(root) do
    point = Path.join(root, ".ecrits/mount")
    :ok = unmount_point(point)
    _ = File.rmdir(point)
    :ok
  end

  defp clean_empty_mount_point(point) do
    _ = File.rmdir(point)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp private_tmp_path("/tmp/" <> rest), do: "/private/tmp/" <> rest
  defp private_tmp_path(_point), do: nil

  defp config_enabled? do
    :ecrits
    |> Application.get_env(:doc_vfs, [])
    |> Keyword.get(:enabled, true) != false
  end

  # `mounting: :virtual` keeps the whole doc-VFS policy surface enabled while
  # substituting kernel mounts with an in-BEAM registry. Policy-level suites
  # need this because a test BEAM cannot bind the FSKit appex while the
  # machine's dev server owns it — a real mount attempt would spend exfuse's
  # serving-verification window and then fail as :mount_not_serving.
  defp virtual_mounting? do
    :ecrits
    |> Application.get_env(:doc_vfs, [])
    |> Keyword.get(:mounting, :real) == :virtual
  end

  @virtual_mounts_key {__MODULE__, :virtual_mounts}

  defp virtual_mounts, do: :persistent_term.get(@virtual_mounts_key, MapSet.new())

  defp put_virtual_mount(root) do
    mounts = virtual_mounts()

    if MapSet.member?(mounts, root) do
      {:ok, :already}
    else
      :persistent_term.put(@virtual_mounts_key, MapSet.put(mounts, root))
      {:ok, :mounted}
    end
  end

  defp delete_virtual_mount(root) do
    mounts = virtual_mounts()

    if MapSet.member?(mounts, root) do
      :persistent_term.put(@virtual_mounts_key, MapSet.delete(mounts, root))
    end

    :ok
  end

  # The backend is determined by the OS alone: macOS mounts through FSKit,
  # every other Unix through the FUSE/libfuse port. There is no macFUSE path
  # and no config/env override — when FSKit is not mountable the status
  # explains why (with the settings URL) instead of reaching for a fallback.
  @doc false
  @spec backend() :: :fskit | :fuse
  def backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
    end
  end

  defp backend_status(:fskit) do
    cond do
      :os.type() != {:unix, :darwin} -> unavailable(:fskit, :fskit_requires_macos)
      not executable?("mount") -> unavailable(:fskit, :missing_mount)
      not fskit_extension_registered?() -> unavailable(:fskit, :fskit_extension_not_registered)
      not fskit_extension_enabled?() -> unavailable(:fskit, :fskit_extension_disabled)
      not fskit_extension_launch_signed?() -> unavailable(:fskit, :fskit_extension_unsigned)
      true -> available(:fskit)
    end
  end

  defp backend_status(:fuse) do
    if port_available?() do
      available(:fuse)
    else
      unavailable(:fuse, :fuse_port_unavailable)
    end
  end

  defp available(backend) do
    %{
      enabled?: true,
      backend: backend,
      reason: nil,
      message: status_message(%{reason: nil, backend: backend}),
      settings_url: nil
    }
  end

  defp unavailable(backend, reason) do
    status = %{enabled?: false, backend: backend, reason: reason}

    %{
      enabled?: false,
      backend: backend,
      reason: reason,
      message: status_message(status),
      settings_url: settings_url_for(reason)
    }
  end

  defp settings_url_for(reason)
       when reason in [:fskit_extension_disabled, :fskit_extension_not_registered],
       do: @fskit_settings_url

  defp settings_url_for(_reason), do: nil

  defp port_available? do
    match?({:ok, _}, Exfuse.App.find_port!())
  rescue
    _ -> false
  end

  defp fskit_extension_enabled? do
    case System.cmd(
           "pluginkit",
           [
             "-m",
             "-A",
             "-D",
             "-v",
             "-p",
             "com.apple.fskit.fsmodule",
             "-i",
             @fskit_extension_id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> fskit_extension_elected?(out)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_elected?(pluginkit_output) do
    pluginkit_output
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line = String.trim_leading(line)
      String.starts_with?(line, "+") and String.contains?(line, @fskit_extension_id)
    end)
  end

  defp fskit_extension_registered? do
    case System.cmd(
           "pluginkit",
           ["-m", "-A", "-D", "-v", "-p", "com.apple.fskit.fsmodule"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.contains?(out, @fskit_extension_id)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_launch_signed? do
    with path when is_binary(path) <- fskit_extension_path(),
         {out, 0} <- System.cmd("codesign", ["-dv", path], stderr_to_stdout: true) do
      not String.contains?(out, "Signature=adhoc")
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_path do
    case System.cmd(
           "pluginkit",
           [
             "-m",
             "-A",
             "-D",
             "-v",
             "-p",
             "com.apple.fskit.fsmodule",
             "-i",
             @fskit_extension_id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, @fskit_extension_id) do
            case Regex.run(~r{(/.+ExfuseFSKitExtension\.appex)}, line) do
              [_, path] -> String.trim(path)
              _ -> nil
            end
          end
        end)

      _ ->
        nil
    end
  end

  defp executable?(name), do: is_binary(System.find_executable(name))
end
