defmodule Ecrits.Fuse.DocFsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Ecrits.Doc.DocumentId
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Fuse.SurfaceContract
  alias Ecrits.Workspace.Session

  test "terminal cleanup CAS cannot remove a newer same-owner edit generation" do
    root = tmp_root("doc_fs_staged_generation")

    on_exit(fn ->
      OpenDocs.unstage(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      edit_id: "same-edit"
    }

    OpenDocs.stage(
      root,
      "doc.hwpx",
      "[",
      {:malformed_xml, "["},
      owner
    )

    assert [{"doc.hwpx", old_bytes, old_reason, old_identity}] =
             OpenDocs.staged_with_identity(root)

    OpenDocs.stage(
      root,
      "doc.hwpx",
      "[",
      {:malformed_xml, "["},
      owner
    )

    assert [{"doc.hwpx", new_bytes, new_reason, new_identity}] =
             OpenDocs.staged_with_identity(root)

    assert new_identity.stage_generation > old_identity.stage_generation

    assert Map.delete(new_identity, :stage_generation) ==
             Map.delete(old_identity, :stage_generation)

    assert new_bytes == old_bytes
    assert new_reason == old_reason

    assert {:error, :stale} =
             OpenDocs.discard_staged(
               root,
               "doc.hwpx",
               old_bytes,
               old_reason,
               old_identity
             )

    assert [{"doc.hwpx", ^new_bytes, ^new_reason, ^new_identity}] =
             OpenDocs.staged_with_identity(root)

    assert :ok =
             OpenDocs.discard_staged(
               root,
               "doc.hwpx",
               new_bytes,
               new_reason,
               new_identity
             )

    assert OpenDocs.staged(root, "doc.hwpx") == :error
  end

  test "terminal cleanup discards the exact captured generation of a closed document" do
    root = tmp_root("doc_fs_closed_stage_cleanup")

    on_exit(fn ->
      OpenDocs.unstage(root, "closed.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "closed-agent",
      instance_id: "closed-instance",
      turn_id: "closed-turn",
      edit_id: "closed-edit"
    }

    OpenDocs.stage(root, "closed.hwpx", "[", {:malformed_xml, "["}, owner)

    assert %{
             committed: [],
             rejected: [],
             pending: []
           } =
             DocFs.flush_staged(root,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id
             )

    assert OpenDocs.staged(root, "closed.hwpx") == :error
  end

  test "doc VFS identity canonicalizes /tmp and /private/tmp spellings" do
    root = Path.join("/tmp", "ecrits-doc-vfs-canonical-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    real_root = DocMount.canonical_root(root)

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    if real_root == root do
      IO.puts("\n[skip] /tmp is not a distinct realpath on this machine")
    else
      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      assert OpenDocs.member?(real_root, "doc.hwpx")
      assert OpenDocs.writable?(real_root)
      assert DocMount.mount_point(root) == Path.join(real_root, ".ecrits")

      assert DocumentId.for_path(Path.join(root, "doc.hwpx"), :hwpx) ==
               DocumentId.for_path(Path.join(real_root, "doc.hwpx"), :hwpx)
    end
  end

  # The editing contract is served as a FILE so it needs no tool: this is the
  # whole reason `doc.open_doc`, which used to carry it in its result, could be
  # deleted. It must be discoverable by `ls`, readable by `cat`, and immutable.
  describe "the mount-level editing contract" do
    test "is listed with a real size, stat-able and readable end to end" do
      root = tmp_root("doc_fs_contract")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      name = SurfaceContract.filename()
      json = SurfaceContract.json()

      # Not a dotfile: a bare `ls` has to show it, or the discovery path this
      # file exists to create does not exist.
      refute String.starts_with?(name, ".")
      # Cannot collide with a projection — every one of those ends in this suffix.
      refute String.ends_with?(name, ".doclang.xml")

      assert {:reply, [{^name, {0o0444, 2, size, _mtime}}], socket} =
               DocFs.handle_event(:readdir, %{path: "/"}, socket)

      assert size == byte_size(json)

      assert {:reply, {0o0444, 2, ^size, _mtime}, socket} =
               DocFs.handle_event(:getattr, %{path: "/" <> name}, socket)

      assert {:reply, ^json, socket} =
               DocFs.handle_event(:read, %{path: "/" <> name, offset: 0, size: 1_000_000}, socket)

      assert {:reply, _handle, _socket} =
               DocFs.handle_event(:open, %{path: "/" <> name, flags: 0}, socket)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["format"]["commit"]["target_path"] == "<document>.doclang.xml"
      assert decoded["format"]["commit"]["temp_path"] == "<document>.doclang.xml.tmp"
    end

    test "refuses every write path" do
      root = tmp_root("doc_fs_contract_readonly")
      OpenDocs.set_writable(root, true)
      on_exit(fn -> OpenDocs.set_writable(root, false) end)

      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      path = "/" <> SurfaceContract.filename()

      # 13 = EACCES. A read-only file the agent cannot replace, truncate,
      # unlink, chmod, or rename a document over.
      assert {:error, 13, _} = DocFs.handle_event(:create, %{path: path, mode: 0o644}, socket)

      assert {:error, 13, _} =
               DocFs.handle_event(:write, %{path: path, offset: 0, data: "x"}, socket)

      assert {:error, 13, _} = DocFs.handle_event(:truncate, %{path: path, size: 0}, socket)
      assert {:error, 13, _} = DocFs.handle_event(:chmod, %{path: path, mode: 0o644}, socket)
      assert {:error, 13, _} = DocFs.handle_event(:unlink, %{path: path}, socket)

      assert {:error, 13, _} =
               DocFs.handle_event(:rename, %{path: path, target: "/moved.json"}, socket)

      assert {:error, 13, _} =
               DocFs.handle_event(:rename, %{path: "/other.tmp", target: path}, socket)
    end
  end

  # The listing is derived from the workspace + the viewer registry, so these
  # tests never call `OpenDocs.open/2`: no tool decides what the mount shows.
  test "readdir lists a viewed root document and nothing else" do
    root = tmp_root("doc_fs_readdir")

    File.write!(Path.join(root, "doc.hwpx"), "fake-hwpx")
    # A supported document with NO viewer has no engine, so it could not answer
    # `getattr` with a real size — listing it would poison its vnode at size 0.
    File.write!(Path.join(root, "unviewed.hwpx"), "fake-hwpx")
    # Not projectable at all: `.txt` has no adapter, `.doc` is in FileIndex's
    # office set but outside `Projection.supported_exts/0`.
    File.write!(Path.join(root, "notes.txt"), "text")
    File.write!(Path.join(root, "legacy.doc"), "binary")

    attach_viewer(root, Path.join(root, "doc.hwpx"), :hwpx)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, names, _socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)
    assert names == [contract_entry(), {"doc.hwpx.doclang.xml", {0o0644, 2, 0}}]
  end

  test "readdir lists a viewed nested document through a flat mount name" do
    root = tmp_root("doc_fs_nested_readdir")
    source = Path.join(root, "drafts/doc.hwpx")

    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "fake-hwpx")

    attach_viewer(root, source, :hwpx)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, names, _socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)
    assert names == [contract_entry(), {"drafts%2Fdoc.hwpx.doclang.xml", {0o0644, 2, 0}}]
  end

  test "readdir is empty when every document's viewer has died" do
    root = tmp_root("doc_fs_dead_viewer_readdir")

    File.write!(Path.join(root, "doc.hwpx"), "fake-hwpx")

    lv = attach_viewer(root, Path.join(root, "doc.hwpx"), :hwpx)
    ref = Process.monitor(lv)
    send(lv, :stop)
    assert_receive {:DOWN, ^ref, :process, ^lv, _reason}

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    # The contract survives an empty listing on purpose: an agent that finds no
    # documents still gets the manual that explains why.
    assert {:reply, names, _socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)
    assert names == [contract_entry()]
  end

  # The bug this pair pins: `readdir` derived its listing while `getattr`/`read`
  # resolved through `OpenDocs`, so `ls` and `ls -l` answered different questions
  # — a viewed document nobody had registered was listed and then reported
  # "No such file or directory" on stat.
  test "a viewed document is listed AND stat-able AND readable with no registration" do
    root = tmp_root("doc_fs_viewed_resolves")
    source = Path.join(root, "doc.hwpx")
    projected = ~s(<doclang version="0.6"></doclang>)

    on_exit(fn -> OpenDocs.close(root, "doc.hwpx") end)

    File.write!(source, "fake-hwpx")
    attach_viewer(root, source, :hwpx)
    refute OpenDocs.member?(root, "doc.hwpx")

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, [_contract, {"doc.hwpx.doclang.xml", _attr}], socket} =
             DocFs.handle_event(:readdir, %{path: "/"}, socket)

    # The engine is browser-side, so this test has no live projection; the served
    # bytes come from the same cache a completed write-back leaves behind.
    OpenDocs.cache_committed(root, "doc.hwpx", projected)

    assert {:reply, {_mode, _nlink, size, _mtime}, socket} =
             DocFs.handle_event(:getattr, %{path: "/doc.hwpx.doclang.xml"}, socket)

    assert size == byte_size(projected)

    assert {:reply, ^projected, socket} =
             DocFs.handle_event(
               :read,
               %{path: "/doc.hwpx.doclang.xml", offset: 0, size: 4096},
               socket
             )

    assert {:reply, _handle, _socket} =
             DocFs.handle_event(:open, %{path: "/doc.hwpx.doclang.xml", flags: 0}, socket)
  end

  test "an unviewed document is neither listed nor stat-able even when registered" do
    root = tmp_root("doc_fs_unviewed_enoent")
    source = Path.join(root, "unviewed.hwpx")

    on_exit(fn -> OpenDocs.close(root, "unviewed.hwpx") end)

    File.write!(source, "fake-hwpx")
    OpenDocs.open(root, "unviewed.hwpx", source_path: source)
    assert OpenDocs.member?(root, "unviewed.hwpx")

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, [_contract], socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)

    assert {:error, 2, socket} =
             DocFs.handle_event(:getattr, %{path: "/unviewed.hwpx.doclang.xml"}, socket)

    assert {:error, 2, socket} =
             DocFs.handle_event(
               :read,
               %{path: "/unviewed.hwpx.doclang.xml", offset: 0, size: 4096},
               socket
             )

    assert {:error, 2, _socket} =
             DocFs.handle_event(:open, %{path: "/unviewed.hwpx.doclang.xml", flags: 0}, socket)
  end

  test "a viewed nested document resolves under the exact flat name readdir listed" do
    root = tmp_root("doc_fs_nested_resolves")
    source = Path.join(root, "drafts/doc.hwpx")
    projected = ~s(<doclang version="0.6"></doclang>)

    on_exit(fn -> OpenDocs.close(root, "drafts%2Fdoc.hwpx") end)

    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "fake-hwpx")
    attach_viewer(root, source, :hwpx)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, [_contract, {"drafts%2Fdoc.hwpx.doclang.xml", _attr}], socket} =
             DocFs.handle_event(:readdir, %{path: "/"}, socket)

    # Keyed by the MOUNT name: the staging/committed cache is per mount entry, so
    # a decoded key here would serve nothing.
    OpenDocs.cache_committed(root, "drafts%2Fdoc.hwpx", projected)

    assert {:reply, {_mode, _nlink, size, _mtime}, socket} =
             DocFs.handle_event(:getattr, %{path: "/drafts%2Fdoc.hwpx.doclang.xml"}, socket)

    assert size == byte_size(projected)

    assert {:reply, ^projected, _socket} =
             DocFs.handle_event(
               :read,
               %{path: "/drafts%2Fdoc.hwpx.doclang.xml", offset: 0, size: 4096},
               socket
             )
  end

  test "a decoded name cannot escape the workspace root" do
    root = tmp_root("doc_fs_decoded_traversal")
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.hwpx")

    File.write!(outside, "fake-hwpx")
    on_exit(fn -> File.rm_rf(outside) end)

    # Both the file AND its viewer exist, so only the confinement can refuse it.
    attach_viewer(root, outside, :hwpx)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, [_contract], socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)

    escapes = [
      # decodes to `../<outside>` — a `..` SEGMENT, which
      # `Exfuse.Fs.Path.canonical/1` rejects instead of resolving
      "..%2F" <> Path.basename(outside),
      "..%2F..%2Fetc%2Fpasswd",
      # `%2E` is not a marker this encoder emits, so this decodes to a literal
      # directory named `%2E%2E` inside the root, not to `..`
      "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd",
      "%2E%2E%2F" <> Path.basename(outside),
      # a name that really contains `%`: decoding must not run twice and turn
      # `%252E` back into `.`
      "%252E%252E%252F%252E%252E%252Fetc%252Fpasswd",
      "%252E%252E%252F" <> Path.basename(outside)
    ]

    for name <- escapes do
      path = "/" <> Ecrits.Doc.Projection.projected_name(name)

      assert {:error, 2, _socket} = DocFs.handle_event(:getattr, %{path: path}, socket),
             "#{name} resolved instead of being refused"

      assert {:error, 2, _socket} =
               DocFs.handle_event(:read, %{path: path, offset: 0, size: 16}, socket),
             "#{name} was readable instead of being refused"
    end
  end

  test "a document whose name contains a literal % is listed and resolves under that name" do
    root = tmp_root("doc_fs_percent_name")
    source = Path.join(root, "50%.hwpx")
    projected = ~s(<doclang version="0.6"></doclang>)

    on_exit(fn -> OpenDocs.close(root, "50%.hwpx") end)

    File.write!(source, "fake-hwpx")
    attach_viewer(root, source, :hwpx)
    OpenDocs.cache_committed(root, "50%.hwpx", projected)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, [_contract, {"50%.hwpx.doclang.xml", _attr}], socket} =
             DocFs.handle_event(:readdir, %{path: "/"}, socket)

    assert {:reply, ^projected, _socket} =
             DocFs.handle_event(
               :read,
               %{path: "/50%.hwpx.doclang.xml", offset: 0, size: 4096},
               socket
             )
  end

  test "the root directory mtime advances with the DERIVED listing" do
    root = tmp_root("doc_fs_root_mtime")
    source = Path.join(root, "doc.hwpx")

    File.write!(source, "fake-hwpx")

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, {_mode, _nlink, _size, empty_mtime}, socket} =
             DocFs.handle_event(:getattr, %{path: "/"}, socket)

    attach_viewer(root, source, :hwpx)

    assert {:reply, {_mode, _nlink, _size, viewed_mtime}, socket} =
             DocFs.handle_event(:getattr, %{path: "/"}, socket)

    assert viewed_mtime > empty_mtime

    assert {:reply, {_mode, _nlink, _size, ^viewed_mtime}, _socket} =
             DocFs.handle_event(:getattr, %{path: "/"}, socket)
  end

  # `mount_name/1` folds a nested path into one mount segment; `source_name/1`
  # must give the path back for EVERY name the workspace scan can produce, or
  # some listed document is unresolvable.
  property "mount_name and source_name round-trip every relative path" do
    # The curated segments are the ones that broke the old pass-through: a
    # literal `%`, and names that already spell an encoder marker.
    segment =
      StreamData.one_of([
        StreamData.member_of(["a", "%", "%25", "%2F", "%252F", "a%2Fb.hwp", "plan..v2", "가"]),
        StreamData.string(:printable, max_length: 8)
      ])

    check all(segments <- StreamData.list_of(segment, min_length: 1, max_length: 4)) do
      relative = Enum.join(segments, "/")

      assert relative |> DocMount.mount_name() |> DocMount.source_name() == relative
    end
  end

  test "mount_name is injective across the nested/root-level boundary" do
    # The collision the pass-through used to admit: root `a%2Fb.hwp` and nested
    # `a/b.hwp` mounted under one entry, so one of them could never be resolved.
    refute DocMount.mount_name("a%2Fb.hwp") == DocMount.mount_name("a/b.hwp")
    assert DocMount.source_name(DocMount.mount_name("a%2Fb.hwp")) == "a%2Fb.hwp"
    assert DocMount.source_name(DocMount.mount_name("a/b.hwp")) == "a/b.hwp"

    # Every ordinary name still mounts unchanged.
    assert DocMount.mount_name("50%.hwpx") == "50%.hwpx"
    assert DocMount.mount_name("report.hwp") == "report.hwp"
  end

  test "chmod accepts writable projected files and atomic rewrite temps" do
    root = tmp_root("doc_fs_chmod")
    source = Path.join(root, "doc.hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    File.write!(source, "fake-hwpx")
    attach_viewer(root, source, :hwpx)
    OpenDocs.open(root, "doc.hwpx")
    OpenDocs.set_writable(root, true)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:noreply, socket} =
             DocFs.handle_event(
               :chmod,
               %{path: "/doc.hwpx.doclang.xml", mode: 0o0644},
               socket
             )

    assert {:reply, _handle, socket} =
             DocFs.handle_event(
               :create,
               %{path: "/doc.hwpx.doclang.xml.tmp", flags: 0, mode: 0o0600},
               socket
             )

    assert {:noreply, _socket} =
             DocFs.handle_event(
               :chmod,
               %{path: "/doc.hwpx.doclang.xml.tmp", mode: 0o0644},
               socket
             )
  end

  test "reads and attrs expose a complete staged structural rewrite instead of truncating committed bytes" do
    root = tmp_root("doc_fs_staged_structural_read")
    source = Path.join(root, "doc.hwpx")
    committed = ~s({"version":"committed","padding":"longer old projection"})
    staged = ~s({"version":"staged"})

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    File.write!(source, "fake-hwpx")
    attach_viewer(root, source, :hwpx)
    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", committed)
    OpenDocs.stage(root, "doc.hwpx", staged, :structural_change)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, ^staged, socket} =
             DocFs.handle_event(
               :read,
               %{path: "/doc.hwpx.doclang.xml", offset: 0, size: byte_size(committed)},
               socket
             )

    assert {:reply, {_mode, _nlink, size, _mtime}, _socket} =
             DocFs.handle_event(:getattr, %{path: "/doc.hwpx.doclang.xml"}, socket)

    assert size == byte_size(staged)
  end

  test "a stale canonical claim cannot overwrite a newer accepted raw projection" do
    root = tmp_root("doc_fs_canonical_cas")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    owner_a = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    owner_b = %{
      agent_id: "agent-b",
      instance_id: "instance-b",
      turn_id: "turn-b",
      source_path: source
    }

    OpenDocs.accept_projection(root, "doc.hwpx", "raw-a", "canonical-a", owner_a)
    assert {:ok, first} = OpenDocs.pending_canonical(root, "doc.hwpx")

    assert [^first] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert [] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "wrong-instance",
               turn_id: "turn-a"
             )

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, first)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw-b", "canonical-b", owner_b)

    assert {:error, :stale} =
             OpenDocs.complete_canonical_echo(root, temp, "doc.hwpx", "canonical-a")

    assert :ok = OpenDocs.cancel_canonical_echo(root, temp)
    assert {:ok, "raw-b"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw-b", bytes: "canonical-b"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "a slower native projection cannot overwrite a newer generation with the same raw predecessor" do
    root = tmp_root("doc_fs_native_generation")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical-initial", %{
      source_path: source
    })

    assert {:ok, "raw", older_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx")

    assert {:ok, "raw", newer_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx")

    assert newer_generation > older_generation

    assert :ok =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-newer",
               newer_generation,
               %{source_path: source, turn_id: "newer"}
             )

    assert {:error, :stale} =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-older",
               older_generation,
               %{source_path: source, turn_id: "older"}
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{bytes: "canonical-newer", generation: ^newer_generation, turn_id: "newer"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "failed in-flight canonical projection remains owner-scoped and terminal retry publishes it" do
    root = tmp_root("doc_fs_in_flight_retry")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", "raw")

    assert {:ok, "raw", generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx", owner)

    assert [
             %{
               accepted_bytes: "raw",
               generation: ^generation,
               name: "doc.hwpx",
               source_path: ^source
             }
           ] =
             OpenDocs.in_flight_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    assert %{
             published: [],
             pending: [{"doc.hwpx", {:canonical_projection_failed, :unavailable}}]
           } =
             DocFs.flush_canonical(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               mounted?: false,
               project_fun: fn ^source -> {:error, :unavailable} end
             )

    assert [%{generation: ^generation}] =
             OpenDocs.in_flight_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert %{published: ["doc.hwpx"], pending: []} =
             DocFs.flush_canonical(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               mounted?: false,
               project_fun: fn ^source -> {:ok, "canonical"} end
             )

    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    assert [] = OpenDocs.in_flight_canonical_entries(root)
  end

  test "newer native stage preserves but blocks an older pending canonical generation" do
    root = tmp_root("doc_fs_in_flight_blocks_stale_pending")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical-old", %{
      agent_id: "agent-old",
      instance_id: "instance-old",
      turn_id: "turn-old",
      source_path: source
    })

    assert {:ok, old_pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    newer_owner = %{
      agent_id: "agent-new",
      instance_id: "instance-new",
      turn_id: "turn-new",
      source_path: source
    }

    assert {:ok, "raw", newer_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx", newer_owner)

    canonical_root = DocMount.canonical_root(root)

    assert [
             {{:__vfs_committed__, ^canonical_root, "doc.hwpx"},
              %{in_flight: %{generation: ^newer_generation}, pending: ^old_pending}}
           ] =
             :ets.lookup(:ecrits_fuse_open_docs, {:__vfs_committed__, canonical_root, "doc.hwpx"})

    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    assert [] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-old",
               instance_id: "instance-old",
               turn_id: "turn-old"
             )

    assert :ok =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-new",
               newer_generation,
               newer_owner
             )

    assert {:ok,
            %{
              bytes: "canonical-new",
              generation: ^newer_generation,
              turn_id: "turn-new"
            }} = OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "killing a canonical echo claimant restores its pending publication" do
    root = tmp_root("doc_fs_echo_claimant_killed")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    parent = self()

    {claimant, monitor_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^claimant, :killed}

    assert_eventually(fn ->
      OpenDocs.canonical_echo(root, temp) == :error and
        OpenDocs.pending_canonical(root, "doc.hwpx") == {:ok, pending}
    end)
  end

  test "flush synchronously reclaims a dead echo before its queued DOWN cleanup" do
    root = tmp_root("doc_fs_dead_echo_flush_race")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(OpenDocs)
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    parent = self()

    {claimant, claimant_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    :ok = :sys.suspend(OpenDocs)

    flush =
      Task.async(fn ->
        DocFs.flush_canonical(root,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a",
          mounted?: false
        )
      end)

    assert_eventually(fn -> reclaim_call_queued?(flush.pid, root) end)

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^claimant_ref, :process, ^claimant, :killed}
    refute Process.alive?(claimant)
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
    assert File.exists?(temp_path)

    :ok = :sys.resume(OpenDocs)

    assert %{published: ["doc.hwpx"], pending: []} = Task.await(flush)
    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
    assert OpenDocs.canonical_echo(root, temp) == :error

    assert [] =
             :ets.match_object(
               :ecrits_fuse_open_docs,
               {{:__vfs_canonical_echo__, DocMount.canonical_root(root), :_}, :_}
             )

    refute File.exists?(temp_path)
  end

  test "dead echo cleanup releases OpenDocs before mounted unlink waits on file_server" do
    root = tmp_root("doc_fs_dead_echo_cleanup_lock")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(OpenDocs)
      _ = :sys.resume(Process.whereis(:file_server_2))
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    parent = self()

    {claimant, claimant_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}

    supervisor = start_supervised!(Task.Supervisor)
    :ok = :sys.suspend(OpenDocs)

    flush =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DocFs.flush_canonical(root,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a",
          mounted?: false
        )
      end)

    assert_eventually(fn -> reclaim_call_queued?(flush.pid, root) end)

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^claimant_ref, :process, ^claimant, :killed}

    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)
    :ok = :sys.resume(OpenDocs)

    assert_eventually(fn -> file_server_call_queued?(file_server, flush.pid) end)

    stage =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.stage(root, "other.hwpx", "[", {:malformed_xml, "["}, owner)
      end)

    assert :ok = Task.await(stage, 1_000)
    :ok = :sys.resume(file_server)

    assert %{published: ["doc.hwpx"], pending: []} = Task.await(flush, 2_000)
    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    refute File.exists?(temp_path)
  end

  test "closing during canonical echo removes the mounted temp after releasing OpenDocs" do
    root = tmp_root("doc_fs_close_during_echo")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(Process.whereis(:file_server_2))
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)

    supervisor = start_supervised!(Task.Supervisor)
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    close =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.close(root, "doc.hwpx")
      end)

    assert_eventually(fn -> file_server_call_queued?(file_server, close.pid) end)

    stage =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.stage(root, "unrelated.hwpx", "bytes", :test)
      end)

    assert :ok = Task.await(stage, 500)
    refute OpenDocs.member?(root, "doc.hwpx")
    assert OpenDocs.canonical_echo(root, temp) == :error
    assert {:ok, "partial-canonical-echo"} = Exfuse.Fs.Real.read_native(temp_path)

    :ok = :sys.resume(file_server)
    assert :ok = Task.await(close, 1_000)
    refute File.exists?(temp_path)
  end

  test "legacy separate canonical pending row migrates without losing its owner" do
    root = tmp_root("doc_fs_legacy_pending_migration")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    canonical_root = DocMount.canonical_root(root)
    committed_key = {:__vfs_committed__, canonical_root, "doc.hwpx"}
    pending_key = {:__vfs_canonical_pending__, canonical_root, "doc.hwpx"}

    legacy_pending = %{
      name: "doc.hwpx",
      accepted_bytes: "raw",
      bytes: "canonical",
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    :ets.insert(:ecrits_fuse_open_docs, {committed_key, "raw"})
    :ets.insert(:ecrits_fuse_open_docs, {pending_key, legacy_pending})

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{bytes: "canonical", generation: 0, turn_id: "turn-a"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")

    assert [
             %{
               agent_id: "agent-a",
               generation: 0,
               instance_id: "instance-a",
               name: "doc.hwpx",
               source_path: ^source,
               turn_id: "turn-a"
             }
           ] =
             OpenDocs.dirty_owner_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert :ets.lookup(:ecrits_fuse_open_docs, pending_key) == []
  end

  test "dirty ownership filters exact identity and source and clears only by CAS" do
    root = tmp_root("doc_fs_dirty_owner_cas")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)

    filters = [
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    ]

    assert [dirty_owner] = OpenDocs.dirty_owner_entries(root, filters)
    assert dirty_owner.source_path == source

    assert [] =
             OpenDocs.dirty_owner_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               source_path: Path.join(root, "another.hwpx")
             )

    stale_owner = Map.update!(dirty_owner, :generation, &(&1 + 1))
    assert {:error, :stale} = OpenDocs.clear_dirty_owner(root, "doc.hwpx", stale_owner)
    assert [^dirty_owner] = OpenDocs.dirty_owner_entries(root, filters)

    assert :ok = OpenDocs.clear_dirty_owner(root, "doc.hwpx", dirty_owner)
    assert [] = OpenDocs.dirty_owner_entries(root, filters)
    assert {:error, :not_dirty} = OpenDocs.clear_dirty_owner(root, "doc.hwpx", dirty_owner)
  end

  test "reserved canonical temps require a registered exact echo and bypass read-only policy" do
    root = tmp_root("doc_fs_internal_canonical_echo")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    attach_viewer(root, source, :hwpx)
    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.set_writable(root, false)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})

    guessed = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:error, 5, _socket} =
             DocFs.handle_event(:create, %{path: "/" <> guessed, flags: 0}, socket)

    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", guessed, pending)

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> guessed, flags: 0}, socket)

    {:reply, 5, socket} =
      DocFs.handle_event(
        :write,
        %{path: "/" <> guessed, handle: handle, offset: 0, data: "wrong"},
        socket
      )

    {:noreply, socket} =
      DocFs.handle_event(:release, %{path: "/" <> guessed, handle: handle}, socket)

    assert {:error, 5, _socket} =
             DocFs.handle_event(
               :rename,
               %{path: "/" <> guessed, target: "/doc.hwpx.doclang.xml"},
               socket
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")
    assert {:ok, %{bytes: "canonical"}} = OpenDocs.pending_canonical(root, "doc.hwpx")

    assert %{published: ["doc.hwpx"], pending: []} =
             DocFs.flush_canonical(root,
               mounted?: true,
               echo_fun: &echo_canonical_through_doc_fs/4
             )

    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")

    read_socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, "canonical", _read_socket} =
             DocFs.handle_event(
               :read,
               %{path: "/doc.hwpx.doclang.xml", offset: 0, size: 64},
               read_socket
             )
  end

  test "canonical publication exceptions restore the pending claim" do
    root = tmp_root("doc_fs_canonical_exception")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})

    assert %{published: [], pending: [{"doc.hwpx", {:canonical_publication_exception, _}}]} =
             DocFs.flush_canonical(root,
               mounted?: true,
               echo_fun: fn _root, _temp, _target, _bytes -> raise "echo crashed" end
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw", bytes: "canonical"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")

    assert %{
             published: [],
             pending: [{"doc.hwpx", {:canonical_publication_caught, :throw, :boom}}]
           } =
             DocFs.flush_canonical(root,
               mounted?: fn _root -> throw(:boom) end
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw", bytes: "canonical"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "closing during an internal echo makes its reserved temp permanently unroutable" do
    root = tmp_root("doc_fs_closed_echo")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket)

    OpenDocs.close(root, "doc.hwpx")
    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", "fresh-open")

    assert OpenDocs.canonical_echo(root, temp) == :error

    assert {:error, 5, socket} =
             DocFs.handle_event(
               :write,
               %{path: "/" <> temp, handle: handle, offset: 0, data: "canonical"},
               socket
             )

    assert {:error, 5, _socket} =
             DocFs.handle_event(
               :rename,
               %{path: "/" <> temp, target: "/doc.hwpx.doclang.xml"},
               socket
             )

    assert {:ok, "fresh-open"} = OpenDocs.committed(root, "doc.hwpx")
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp reclaim_call_queued?(caller, root) do
    canonical_root = DocMount.canonical_root(root)

    case Process.info(Process.whereis(OpenDocs), :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", {^caller, _tag},
           {:reclaim_dead_canonical_echoes, ^canonical_root, _filters}} ->
            true

          _message ->
            false
        end)

      _unavailable ->
        false
    end
  end

  defp file_server_call_queued?(file_server, caller) do
    case Process.info(file_server, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", {^caller, _tag}, _request} -> true
          _message -> false
        end)

      _unavailable ->
        false
    end
  end

  defp echo_canonical_through_doc_fs(root, temp, target, bytes) do
    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket)

    {:reply, size, socket} =
      DocFs.handle_event(
        :write,
        %{path: "/" <> temp, handle: handle, offset: 0, data: bytes},
        socket
      )

    true = size == byte_size(bytes)

    {:noreply, socket} =
      DocFs.handle_event(
        :fsync,
        %{path: "/" <> temp, handle: handle, datasync: false, flags: 0},
        socket
      )

    {:noreply, socket} =
      DocFs.handle_event(:release, %{path: "/" <> temp, handle: handle}, socket)

    {:noreply, _socket} =
      DocFs.handle_event(
        :rename,
        %{path: "/" <> temp, target: "/" <> target},
        socket
      )

    :ok
  end

  # Real size, read-only mode, constant mtime: the contract's bytes are generated
  # in-process, so unlike a projection it needs no engine to be sized.
  defp contract_entry,
    do: {SurfaceContract.filename(), {0o0444, 2, SurfaceContract.size(), 1_700_000_000}}

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "ecrits-#{label}-#{System.unique_integer([:positive])}")
    |> tap(&File.mkdir_p!/1)
    |> tap(fn root -> on_exit(fn -> File.rm_rf(root) end) end)
  end

  # Register a stand-in browser authority for `source`, exactly as `WorkspaceLive`
  # does once the editor hook reports `document.viewer.ready`. The id is derived
  # the same way the registry keys it, so a second spelling here would make the
  # listing silently empty.
  defp attach_viewer(root, source, kind) do
    lv = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> if Process.alive?(lv), do: send(lv, :stop) end)

    :ok = Session.attach_viewer(root, DocumentId.for_path(source, kind), lv)
    lv
  end
end
