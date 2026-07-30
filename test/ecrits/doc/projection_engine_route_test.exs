defmodule Ecrits.Doc.ProjectionEngineRouteTest do
  @moduledoc """
  The doc VFS projection's ENGINE seam (Layer 4, 2026-07-26).

  `Projection` used to read its IR by opening the document into a server-side
  Editor registry and calling the backend. Both engine deps are gone, so that
  path could never return IR again (`backend_for/1` was deleted 2026-07-28 and
  the registry itself on 2026-07-29) — `doc.open_doc` answered
  `mount_error: {:projection_unavailable, {:unsupported_kind, :hwp}}` for a
  document sitting open on screen, and `<name>.doclang.xml` was never created.

  The engine now lives in the BROWSER, so the projection looks up the viewer
  holding the document (`Ecrits.Workspace.Session.viewer/2`) and asks it for its
  full element enumeration over `Ecrits.Doc.BrowserBridge`. These tests pin the
  three behaviours that make that honest:

    * an attached viewer's IR really becomes the mounted DocLang bytes;
    * a document with NO viewer fails with a named, actionable `:no_engine`
      error rather than mounting an empty or partial projection;
    * the viewer's own coverage statement reaches the caller, so a partial arm
      (HWP's `doc-ops-v1`, which has no element enumerator) can never be
      mistaken for a complete one.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Projection
  alias Ecrits.Workspace.Session

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "projection_engine_route_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "report.hwp")
    File.write!(path, <<0, 1, 2, 3>>)

    on_exit(fn ->
      if pid = Session.whereis(root), do: Process.exit(pid, :kill)
      File.rm_rf(root)
    end)

    {:ok, root: root, path: path}
  end

  describe "browser arm" do
    test "the viewer's element enumeration becomes the mounted DocLang bytes", %{
      root: root,
      path: path
    } do
      viewer =
        elements_viewer(self(), %{
          "elements" => [
            %{"type" => "paragraph", "text" => "계약서", "ref" => paragraph_ref(0)},
            %{"type" => "paragraph", "text" => "제1조", "ref" => paragraph_ref(1)}
          ],
          "coverage" => "body_paragraphs",
          "complete" => false
        })

      attach(root, path, viewer)

      assert {:ok, bytes} = Projection.project_file(path, root: root)

      assert bytes ==
               ~s(<doclang version="0.6"><text>계약서</text><text>제1조</text></doclang>)

      # One `:elements` request, guarded by the document identity — a tab switch
      # mid-flight must not answer with a different document's IR.
      assert_received {:browser_request, :elements, %{}}
    end

    test "a bare list reply is accepted (no envelope required)", %{root: root, path: path} do
      viewer =
        elements_viewer(self(), [
          %{"type" => "paragraph", "text" => "본문", "ref" => paragraph_ref(0)}
        ])

      attach(root, path, viewer)

      assert {:ok, ~s(<doclang version="0.6"><text>본문</text></doclang>)} =
               Projection.project_file(path, root: root)
    end

    test "a reply that is not an element enumeration is rejected, not projected", %{
      root: root,
      path: path
    } do
      viewer = elements_viewer(self(), %{"ok" => true})
      attach(root, path, viewer)

      assert {:error, {:browser_elements_invalid, %{"ok" => true}}} =
               Projection.project_file(path, root: root)
    end

    test "coverage/2 reports the viewer's own statement of what it could enumerate", %{
      root: root,
      path: path
    } do
      viewer =
        elements_viewer(self(), %{
          "elements" => [],
          "coverage" => "body_paragraphs",
          "complete" => false,
          "note" => "doc-ops-v1 exposes no element enumerator"
        })

      attach(root, path, viewer)

      # No `"arm"` key: with one possible producer the field named nothing.
      assert {:ok, coverage} = Projection.coverage(path, root: root)

      assert coverage == %{
               "coverage" => "body_paragraphs",
               "complete" => false,
               "note" => "doc-ops-v1 exposes no element enumerator"
             }
    end
  end

  describe "cold documents (no engine anywhere)" do
    test "project_file/2 fails with a named, actionable reason", %{root: root, path: path} do
      assert {:error, {:no_engine, info}} = Projection.project_file(path, root: root)

      refute Map.has_key?(info, :arm)
      assert info.kind == :hwp
      assert info.reason == :no_viewer
      assert info.path == path
      assert info.hint =~ "BROWSER"
      assert info.hint =~ "report.hwp"
    end

    test "fingerprint/2 fails the same way rather than fingerprinting nothing", %{
      root: root,
      path: path
    } do
      assert {:error, {:no_engine, _info}} = Projection.fingerprint(path, root: root)
    end

    test "a document outside every running workspace is cold too", %{path: path} do
      assert {:error, {:no_engine, %{reason: :no_viewer}}} = Projection.project_file(path)
    end
  end

  describe "Session.workspace_for/1" do
    test "recovers the running workspace that contains a document path", %{
      root: root,
      path: path
    } do
      attach(root, path, elements_viewer(self(), %{"elements" => []}))

      assert Session.workspace_for(path) == Ecrits.Fuse.DocMount.canonical_root(root)
    end

    test "is nil when no running session contains the path" do
      assert Session.workspace_for("/nowhere/at/all/report.hwp") == nil
    end
  end

  # --- helpers --------------------------------------------------------------

  defp paragraph_ref(paragraph),
    do: %{"section" => 0, "paragraph" => paragraph, "offset" => 0}

  # Register `viewer` as the workspace Session's browser authority for `path`,
  # exactly as `WorkspaceLive` does when the editor hook reports
  # `document.viewer.ready`.
  defp attach(root, path, viewer) do
    document_id = Ecrits.Doc.DocumentId.for_path(path, :hwp)
    :ok = Session.attach_viewer(root, document_id, viewer)
    document_id
  end

  # A stand-in for the viewing LiveView: answers one BrowserBridge verb with a
  # canned reply and completes the ACK handshake the bridge requires before a
  # successful result may escape to the caller.
  defp elements_viewer(parent, reply) do
    lv =
      spawn(fn -> elements_viewer_loop(parent, reply) end)

    on_exit(fn -> if Process.alive?(lv), do: send(lv, :stop) end)
    lv
  end

  defp elements_viewer_loop(parent, reply) do
    receive do
      {:doc_browser_request, from, ref, verb, payload, _expected_document_id} ->
        send(parent, {:browser_request, verb, payload})
        send(from, {:doc_browser_reply, ref, {:ok, reply}})
        acknowledge_completion(from, ref)
        elements_viewer_loop(parent, reply)

      {:doc_browser_request, from, ref, verb, payload} ->
        send(parent, {:browser_request, verb, payload})
        send(from, {:doc_browser_reply, ref, {:ok, reply}})
        acknowledge_completion(from, ref)
        elements_viewer_loop(parent, reply)

      :stop ->
        :ok
    end
  end

  defp acknowledge_completion(from, ref) do
    receive do
      {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
    after
      1_000 -> :ok
    end
  end
end
