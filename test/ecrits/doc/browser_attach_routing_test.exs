defmodule Ecrits.Doc.BrowserAttachRoutingTest do
  @moduledoc """
  Regression: a doc.* call must operate on the document the call NAMES, routing
  to the browser arm ONLY when THAT document is the currently-viewed one.

  Live bug (chat-rail): a single viewing LiveView views doc1, then navigates to
  doc2. Each view calls `Pool.attach_browser(doc, lv)` but nothing ever detaches
  the previously-viewed doc, so doc1 stays `:browser`-backed by a stale lv. When
  the agent later opens/reads doc1 (a file the user names but is no longer
  viewing), the request routes `{:browser, lv}` and the LiveView substitutes its
  *currently-viewed* doc id — so the agent reads/edits the viewed doc regardless
  of the path it named ("doc.open returns the currently-open document").

  Invariant under test: a given viewer (lv pid) is the browser authority for AT
  MOST ONE doc — the one it is currently viewing. Everything else routes to its
  server NIF, independently of what is open in the browser.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    {:ok, pool} = start_supervised({Pool, name: nil})
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)
    {:ok, pool: pool}
  end

  defp ctx(pool), do: %{pool: pool}

  defp idle_lv do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "attach_browser is exclusive per viewer (the navigation invariant)" do
    test "viewing a second doc detaches the viewer from the first", %{pool: pool} do
      {:ok, doc1} = Pool.open(pool, "/abs/doc1.hwp", kind: :hwp, open_opts: [__text__: "ONE"])
      {:ok, doc2} = Pool.open(pool, "/abs/doc2.hwp", kind: :hwp, open_opts: [__text__: "TWO"])

      lv = idle_lv()

      # User views doc1, then navigates to doc2 in the SAME LiveView.
      :ok = Pool.attach_browser(pool, doc1, lv)
      :ok = Pool.attach_browser(pool, doc2, lv)

      # doc2 (currently viewed) routes to the browser; doc1 (no longer viewed)
      # must fall back to its server editor — NOT stay stuck on the stale viewer.
      assert {:browser, ^lv} = Pool.route(pool, doc2)
      assert {:server, editor1} = Pool.route(pool, doc1)
      assert is_pid(editor1)
    end

    test "two distinct viewers each keep their own one browser-backed doc", %{pool: pool} do
      {:ok, doc1} = Pool.open(pool, "/abs/v1.hwp", kind: :hwp, open_opts: [__text__: "A"])
      {:ok, doc2} = Pool.open(pool, "/abs/v2.hwp", kind: :hwp, open_opts: [__text__: "B"])

      lv_a = idle_lv()
      lv_b = idle_lv()

      :ok = Pool.attach_browser(pool, doc1, lv_a)
      :ok = Pool.attach_browser(pool, doc2, lv_b)

      # Independent viewers do not poach each other's attachment.
      assert {:browser, ^lv_a} = Pool.route(pool, doc1)
      assert {:browser, ^lv_b} = Pool.route(pool, doc2)
    end

    test "detach_browser/3 relinquishes a viewer's browser claim", %{pool: pool} do
      {:ok, doc} = Pool.open(pool, "/abs/d.hwp", kind: :hwp, open_opts: [__text__: "X"])
      lv = idle_lv()

      :ok = Pool.attach_browser(pool, doc, lv)
      assert {:browser, ^lv} = Pool.route(pool, doc)

      :ok = Pool.detach_browser(pool, doc, lv)
      assert {:server, editor} = Pool.route(pool, doc)
      assert is_pid(editor)
    end
  end

  describe "doc.* operate on the NAMED doc while a viewer is attached (server arm)" do
    test "open + read + find + edit target the second doc, not the viewed one", %{pool: pool} do
      # Viewed doc (HWP-B) — browser-backed by a viewer.
      {:ok, %{"document" => viewed}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "/abs/HWP-B.hwp",
          "open_opts" => [__text__: "VIEWED-B 제1조 (viewed only)"]
        })

      lv = idle_lv()
      :ok = Pool.attach_browser(pool, viewed, lv)
      :ok = Pool.set_active(pool, viewed)

      # Agent opens a SECOND, distinct headless doc (HWP-A) it must read.
      {:ok, %{"document" => second}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "/abs/HWP-A.hwp",
          "open_opts" => [__text__: "SECOND-A 제9조 (source text)"]
        })

      # (a) distinct ids
      refute second == viewed

      # The viewed doc routes to the browser; the second routes to its server NIF.
      assert {:browser, ^lv} = Pool.route(pool, viewed)
      assert {:server, _editor} = Pool.route(pool, second)

      # (b) doc.read / doc.find on the second return ITS content (not the viewed one).
      assert {:ok, %{"text" => text}} = Tools.call(ctx(pool), "doc.read", %{"document" => second})
      assert text =~ "SECOND-A"
      refute text =~ "VIEWED-B"

      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => second, "pattern" => "제9조"})

      assert m["text"] =~ "제9조"

      # (c) an edit lands on the second doc ONLY.
      assert {:ok, %{"ok" => true, "revision" => 1}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => second,
                 "op" => %{"op" => "replace_text", "query" => "제9조", "replacement" => "ARTICLE9"},
                 "base_revision" => 0
               })

      assert {:ok, %{"text" => after_text}} =
               Tools.call(ctx(pool), "doc.read", %{"document" => second})

      assert after_text =~ "ARTICLE9"

      # The viewed doc still routes to the browser (its own model is the authority)
      # and was not touched by the edit that targeted the second doc.
      assert {:browser, ^lv} = Pool.route(pool, viewed)
    end

    test "the previously-viewed file (now navigated away) reads via the server arm", %{
      pool: pool
    } do
      # User views doc1, then navigates to doc2 in the same viewer.
      {:ok, %{"document" => doc1}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "/abs/L3-8.hwp",
          "open_opts" => [__text__: "L3-8 SOURCE 제3조"]
        })

      {:ok, %{"document" => doc2}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "/abs/plan.hwp",
          "open_opts" => [__text__: "PLAN VIEWED 제1조"]
        })

      lv = idle_lv()
      :ok = Pool.attach_browser(pool, doc1, lv)
      :ok = Pool.attach_browser(pool, doc2, lv)
      :ok = Pool.set_active(pool, doc2)

      # Agent is asked to use the text of the *previously-viewed* L3-8 file. It
      # opens it (same path -> same id) and reads it. Before the fix this routes
      # to the browser and yields the currently-viewed doc2 ("PLAN VIEWED"); after
      # the fix doc1 is server-backed again so the read returns L3-8's own text.
      {:ok, %{"document" => reopened}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "/abs/L3-8.hwp"})

      assert reopened == doc1
      assert {:server, _} = Pool.route(pool, doc1)

      assert {:ok, %{"text" => text}} = Tools.call(ctx(pool), "doc.read", %{"document" => doc1})
      assert text =~ "L3-8 SOURCE"
      refute text =~ "PLAN VIEWED"
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
