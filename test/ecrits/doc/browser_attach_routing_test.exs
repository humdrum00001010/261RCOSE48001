defmodule Ecrits.Doc.BrowserAttachRoutingTest do
  @moduledoc """
  Regression: a doc.* call must operate on the document the call NAMES, routing
  to the browser arm ONLY when THAT document is the currently-viewed one.

  Live bug (chat-rail): a single viewing LiveView views doc1, then navigates to
  doc2. Each view registers itself as the viewer; nothing detached the
  previously-viewed doc, so doc1 stayed browser-backed by a stale lv. When the
  agent later opened/read doc1 (a file the user names but is no longer viewing),
  the request routed `{:browser, lv}` and the LiveView substituted its
  *currently-viewed* doc id — so the agent read/edited the viewed doc regardless
  of the path it named.

  Invariant under test: a given viewer (lv pid) is the browser authority for AT
  MOST ONE doc — the one it is currently viewing. Everything else routes to its
  server NIF, independently of what is open in the browser.

  The `viewers` map lives in `Ecrits.Workspace.Session`, so this test drives
  `Session.attach_viewer`/`Session.viewer` and a Tools ctx carrying
  `:session_path` (the per-workspace Session key).

  Scope after the 2026-07-29 Pool deletion: the viewer registry is the WHOLE
  routing decision. A document nobody views is not routable at all, where it
  once fell back to a server Editor — so the cases here assert the registry's
  own invariants (exclusive per viewer, newest-active, promote on detach/DOWN)
  and that doc.* reaches the browser arm for exactly the named document.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.DocumentId
  alias Ecrits.Doc.Tools
  alias Ecrits.Workspace.Session

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    # A unique workspace path keys this test's Session (started lazily by the
    # viewer/ownership calls); the app supervision tree runs the SessionSupervisor.
    path = Path.join(System.tmp_dir!(), "ws_route_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if pid = Session.whereis(path), do: Process.exit(pid, :kill)
      restore(:ehwp, :runtime, prev)
    end)

    {:ok, path: path}
  end

  # An agent ctx that routes via the workspace Session (the production path).
  defp ctx(path) do
    %{
      agent_id: "fg",
      instance_id: "fg-instance",
      turn_id: "fg-turn",
      session_path: path
    }
  end

  defp idle_lv do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp browser_reply_lv(parent, result) do
    spawn(fn ->
      receive do
        {:doc_browser_request, from, ref, verb, payload} ->
          send(parent, {:browser_request, verb, payload})
          send(from, {:doc_browser_reply, ref, {:ok, result}})
          acknowledge_browser_completion(from, ref)

          receive do
            :stop -> :ok
          after
            1_000 -> :ok
          end
      end
    end)
  end

  defp render_viewer_lv(parent, dirty?) when is_boolean(dirty?) do
    spawn(fn -> render_viewer_loop(parent, dirty?) end)
  end

  defp render_viewer_loop(parent, dirty?) do
    receive do
      {:doc_viewer_state_request, from, ref, document_id} ->
        send(parent, {:viewer_state_request, document_id})
        send(from, {:doc_viewer_state_reply, ref, {:ok, %{dirty: dirty?}}})
        render_viewer_loop(parent, dirty?)

      {:doc_browser_request, from, ref, verb, payload} ->
        send(parent, {:browser_request, verb, payload})
        send(from, {:doc_browser_reply, ref, {:error, "forced browser snapshot"}})
        acknowledge_browser_completion(from, ref)
        render_viewer_loop(parent, dirty?)

      :stop ->
        :ok
    end
  end

  defp acknowledge_browser_completion(from, ref) do
    receive do
      {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
    end
  end

  # The handle a document has whether or not anything holds it: a pure function
  # of (path, kind), which is exactly what the viewer registry is keyed by.
  defp doc_id(path, kind \\ :hwp), do: DocumentId.for_path(path, kind)

  describe "attach_viewer is exclusive per viewer (the navigation invariant)" do
    test "viewing a second doc detaches the viewer from the first", %{path: path} do
      doc1 = doc_id("/abs/doc1.hwp")
      doc2 = doc_id("/abs/doc2.hwp")

      lv = idle_lv()

      # User views doc1, then navigates to doc2 in the SAME LiveView.
      :ok = Session.attach_viewer(path, doc1, lv)
      :ok = Session.attach_viewer(path, doc2, lv)

      # doc2 (currently viewed) is held by the browser; doc1 (no longer viewed)
      # must have NO viewer — NOT stay stuck on the stale one. Nothing else can
      # hold it, so doc1 is now unaddressable, which is the accepted price.
      assert Session.viewer(path, doc2) == lv
      assert Session.viewer(path, doc1) == nil
    end

    test "two distinct viewers each keep their own one browser-backed doc", %{path: path} do
      doc1 = doc_id("/abs/v1.hwp")
      doc2 = doc_id("/abs/v2.hwp")

      lv_a = idle_lv()
      lv_b = idle_lv()

      :ok = Session.attach_viewer(path, doc1, lv_a)
      :ok = Session.attach_viewer(path, doc2, lv_b)

      # Independent viewers do not poach each other's attachment.
      assert Session.viewer(path, doc1) == lv_a
      assert Session.viewer(path, doc2) == lv_b
    end

    test "same-document viewers promote the next live pid on detach and DOWN", %{path: path} do
      doc = doc_id("/abs/concurrent.hwp")

      lv_a = idle_lv()
      lv_b = idle_lv()

      :ok = Session.attach_viewer(path, doc, lv_a)
      :ok = Session.attach_viewer(path, doc, lv_b)

      assert Session.viewer(path, doc) == lv_b

      :ok = Session.detach_viewer(path, doc, lv_b)
      assert Session.viewer(path, doc) == lv_a

      :ok = Session.attach_viewer(path, doc, lv_b)
      assert Session.viewer(path, doc) == lv_b

      ref = Process.monitor(lv_b)
      send(lv_b, :stop)
      assert_receive {:DOWN, ^ref, :process, ^lv_b, :normal}

      assert Session.viewer(path, doc) == lv_a

      :ok = Session.detach_viewer(path, doc, lv_a)
      assert Session.viewer(path, doc) == nil

      send(lv_a, :stop)
    end

    test "moving a fallback viewer preserves the other document viewer", %{path: path} do
      doc1 = doc_id("/abs/shared-then-moved.hwp")
      doc2 = doc_id("/abs/fallback-destination.hwp")

      lv_a = idle_lv()
      lv_b = idle_lv()

      :ok = Session.attach_viewer(path, doc1, lv_a)
      :ok = Session.attach_viewer(path, doc1, lv_b)
      assert Session.viewer(path, doc1) == lv_b

      :ok = Session.attach_viewer(path, doc2, lv_a)

      assert Session.viewer(path, doc1) == lv_b
      assert Session.viewer(path, doc2) == lv_a

      send(lv_a, :stop)
      send(lv_b, :stop)
    end

    test "legacy hot state with one viewer pid normalizes before promotion", %{path: path} do
      doc = doc_id("/abs/legacy-viewer.hwp")

      legacy_lv = idle_lv()
      newest_lv = idle_lv()

      :ok = Session.attach_viewer(path, doc, legacy_lv)
      session_pid = Session.whereis(path)

      :sys.replace_state(session_pid, fn state ->
        %{state | viewers: %{doc => legacy_lv}}
      end)

      assert Session.viewer(path, doc) == legacy_lv
      assert %{^doc => [^legacy_lv]} = :sys.get_state(session_pid).viewers

      :ok = Session.attach_viewer(path, doc, newest_lv)
      assert Session.viewer(path, doc) == newest_lv
      assert %{^doc => [^newest_lv, ^legacy_lv]} = :sys.get_state(session_pid).viewers

      :ok = Session.detach_viewer(path, doc, newest_lv)
      assert Session.viewer(path, doc) == legacy_lv

      send(legacy_lv, :stop)
      send(newest_lv, :stop)
    end

    test "detach_viewer/3 relinquishes a viewer's browser claim", %{path: path} do
      doc = doc_id("/abs/d.hwp")
      lv = idle_lv()

      :ok = Session.attach_viewer(path, doc, lv)
      assert Session.viewer(path, doc) == lv

      :ok = Session.detach_viewer(path, doc, lv)
      assert Session.viewer(path, doc) == nil
    end
  end

  describe "doc.* operate on the NAMED doc while a viewer is attached" do
    test "browser-routed batch edit rejects retired metadata before it reaches the browser", %{
      path: path
    } do
      File.mkdir_p!(path)
      doc = doc_id(Path.join(path, "viewed-batch.hwp"))

      live_result = %{
        "ok" => true,
        "applied" => 2,
        "failed" => 0,
        "results" => [%{"ok" => true}, %{"ok" => true}]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:error, %{"error" => "invalid_op", "message" => message}} =
               Tools.call(ctx(path), "doc.edit", %{
                 "document" => doc,
                 "ops" => [
                   %{
                     "op" => "replace_text",
                     "query" => "A",
                     "replacement" => "AA",
                     "base_revision" => 7
                   },
                   %{
                     "op" => "replace_text",
                     "query" => "B",
                     "replacement" => "BB",
                     "current_version" => 8
                   }
                 ]
               })

      assert message =~ "base_revision"
      refute_receive {:browser_request, :edit, _payload}, 50

      send(lv, :stop)
    end

    test "doc.get on a viewed office document resolves through the browser IR", %{path: path} do
      doc_path = Path.join(path, "browser.docx")
      doc = doc_id(doc_path, :docx)

      live_result = %{
        "ref" => "tbl[Table1]/cell[A1]",
        "type" => "cell",
        "kind" => "cell",
        "values" => %{"text" => "LIVE_BROWSER_TEXT"},
        "properties" => %{"text" => "LIVE_BROWSER_TEXT"},
        "settable" => ["CharWeight"],
        "children" => [],
        "ir" => %{"ref" => "tbl[Table1]/cell[A1]", "text" => "LIVE_BROWSER_TEXT"}
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      # doc.get is office-only, and "is this office?" is now answered by the
      # caller's own active document, not by a registry row.
      tool_ctx =
        path
        |> ctx()
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, doc_path)

      assert {:ok, ^live_result} =
               Tools.call(tool_ctx, "doc.get", %{
                 "document" => doc,
                 "ref" => "tbl[Table1]/cell[A1]"
               })

      assert_receive {:browser_request, :get, %{ref: "tbl[Table1]/cell[A1]", props: nil}}

      send(lv, :stop)
    end

    test "doc.save accepts the current browser document id", %{path: path} do
      doc_path = Path.join(path, "browser-save.pptx")
      doc = doc_id(doc_path, :pptx)
      bytes = "PPTX-BROWSER-BYTES"
      File.mkdir_p!(path)

      lv =
        browser_reply_lv(self(), %{
          "bytes" => bytes,
          "format" => "pptx"
        })

      :ok = Session.attach_viewer(path, doc, lv)

      tool_ctx =
        path
        |> ctx()
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, doc_path)

      assert {:ok, %{"current_document" => current}} = Tools.call(tool_ctx, "doc.context", %{})
      assert current["document"] == doc
      assert current["path"] == doc_path
      assert current["backing"] == "browser"

      assert {:ok, %{"ok" => true}} =
               Tools.call(tool_ctx, "doc.save", %{"document" => current["document"]})

      assert_receive {:browser_request, :save, %{}}
      assert File.read!(doc_path) == bytes

      send(lv, :stop)
    end

    # doc.render always snapshots the viewer now. It used to take a server-twin
    # fast path for a CLEAN viewed office document, asking the viewer whether it
    # was dirty first; that twin never existed, so the question is gone too.
    test "doc.render on a viewed office document snapshots the browser", %{path: path} do
      doc_path = Path.join(path, "dirty-render.pptx")
      doc = doc_id(doc_path, :pptx)

      lv = render_viewer_lv(self(), true)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:error, %{"error" => error}} =
               Tools.call(ctx(path), "doc.render", %{
                 "document" => doc,
                 "page" => "Slide1",
                 "width" => 640
               })

      assert error =~ "forced browser snapshot"
      assert_receive {:browser_request, :save, %{}}
      refute_receive {:viewer_state_request, ^doc}, 50

      send(lv, :stop)
    end

    test "a viewed xlsx is the browser-backed current document", %{path: path} do
      workbook_path = Path.join(path, "sample.xlsx")
      doc = doc_id(workbook_path, :xlsx)

      live_result = %{
        "pattern" => "Revenue",
        "type" => nil,
        "matches" => [
          %{
            "ref" => "sheet[Sheet1]/cell[B2]",
            "type" => "cell",
            "text" => "Revenue",
            "sheet" => "Sheet1",
            "row" => 2,
            "col" => 2
          }
        ]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      agent_ctx =
        ctx(path)
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, "sample.xlsx")

      assert {:ok, %{"current_document" => current}} =
               Tools.call(agent_ctx, "doc.context", %{})

      assert current["document"] == doc
      assert current["kind"] == "xlsx"
      assert current["path"] == "sample.xlsx"
      assert current["backing"] == "browser"

      assert {:ok, ^live_result} =
               Tools.call(agent_ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "Revenue"
               })

      assert_receive {:browser_request, :find, %{pattern: "Revenue"}}

      send(lv, :stop)
    end

    test "browser-backed doc.find compacts long match text before returning", %{path: path} do
      deck_path = Path.join(path, "long-find.pptx")
      doc = doc_id(deck_path, :pptx)

      text =
        String.duplicate("Intro ", 40) <>
          "Private Timer Clock" <>
          String.duplicate(" tail", 40)

      live_result = %{
        "pattern" => "Private Timer Clock",
        "type" => nil,
        "matches" => [
          %{
            "ref" => "page[1]/shape[long]",
            "type" => "text_frame",
            "text" => text
          }
        ]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      agent_ctx =
        ctx(path)
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, "long-find.pptx")

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(agent_ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "Private Timer Clock"
               })

      assert_receive {:browser_request, :find, %{pattern: "Private Timer Clock"}}
      assert match["ref"] == "page[1]/shape[long]"
      assert match["text"] =~ "Private Timer Clock"
      assert match["text_truncated"] == true
      refute Map.has_key?(match, "text_length")
      assert String.length(match["text"]) <= 54
      refute match["text"] == text

      send(lv, :stop)
    end

    # A path argument resolves by DERIVING the id from (path, kind) and asking
    # whether a viewer holds it — the id scheme is what makes a path a handle.
    test "doc.save accepts the viewed document path and routes to the browser model", %{
      path: path
    } do
      relative_path = "viewed-save.hwp"
      absolute_path = Path.join(path, relative_path)
      File.mkdir_p!(path)

      File.write!(absolute_path, "DISK COPY")
      doc = doc_id(absolute_path)

      lv = browser_reply_lv(self(), %{"bytes_base64" => Base.encode64("VIEWER BYTES")})
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(path), "doc.save", %{"document" => relative_path})

      assert_receive {:browser_request, :save, %{}}
      assert File.read!(absolute_path) == "VIEWER BYTES"

      send(lv, :stop)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
