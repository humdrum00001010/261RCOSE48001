defmodule Ecrits.Doc.PoolTwinSyncTest do
  @moduledoc """
  Regression: the browser-viewer checkpoint must refresh the agent pool's
  SERVER twin (`Pool.refresh_by_path/3` -> `Editor.reload_from_bytes/2`).

  Live bug: while a doc was viewed, agent edits applied to the browser WASM
  model; when the viewer detached (tab switch), doc.* routing fell back to the
  pool's NIF copy — still holding the bytes it was OPENED with — and a
  server-routed `doc.save` exported that stale model over the browser's edits
  (observed: an inserted footnote vanished from disk after a tab switch).
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    {:ok, pool} = start_supervised({Pool, name: nil})

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:ehwp, :runtime)
      else
        Application.put_env(:ehwp, :runtime, prev)
      end
    end)

    path = "/tmp/twin_sync_#{System.unique_integer([:positive])}/contract.hwp"
    {:ok, id} = Pool.open(pool, path, kind: :hwp)
    {:ok, pool: pool, path: path, id: id}
  end

  test "refresh_by_path replaces the server twin's model from checkpoint bytes",
       %{pool: pool, path: path, id: id} do
    {:ok, %{text: before}} = Pool.with_doc(pool, id, &Editor.read(&1, []))
    refute before =~ "브라우저 체크포인트 본문"

    assert :ok = Pool.refresh_by_path(pool, path, "브라우저 체크포인트 본문")

    {:ok, %{text: after_text}} = Pool.with_doc(pool, id, &Editor.read(&1, []))
    assert after_text == "브라우저 체크포인트 본문"

    # The twin now MIRRORS the browser authority — it carries no local edits of
    # its own, so it must read as clean (a dirty twin would trigger the
    # reverse-sync path and hand these bytes back to the next viewer).
    assert Pool.with_doc(pool, id, &Editor.dirty?/1) == false
  end

  test "refresh_by_path without an open twin is a no-op", %{pool: pool} do
    assert :ok = Pool.refresh_by_path(pool, "/tmp/never-opened.hwp", "bytes")
  end

  test "export_bytes returns the in-memory model without touching disk",
       %{pool: pool, path: path, id: id} do
    assert :ok = Pool.refresh_by_path(pool, path, "수정된 본문")
    assert {:ok, "수정된 본문"} = Pool.with_doc(pool, id, &Editor.export_bytes/1)
  end
end
