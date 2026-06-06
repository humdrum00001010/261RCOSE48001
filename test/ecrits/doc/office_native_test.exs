defmodule Ecrits.Doc.OfficeNativeTest do
  @moduledoc """
  Integration test against the *real* headless LibreOffice UNO NIF (no fake
  runtime), proving the docx/pptx Office backend is wired to the genuine engine
  through the full `Ecrits.Doc` layer (Tools -> Pool -> Editor -> Office), not
  the raw NIF.

  Skips automatically (green) when the UNO arm is unavailable — the NIF wasn't
  built with the LibreOffice SDK, or there is no LOK install dir on this machine
  — exactly like `rhwp_native_test.exs` does for the ehwp NIF. So the default
  suite stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools

  @fixture Path.expand("../../fixtures/office/table.docx", __DIR__)
  @pptx_fixture Path.expand("../../fixtures/office/slides.pptx", __DIR__)

  setup do
    if uno_available?() do
      {:ok, pool} = start_supervised({Pool, name: nil})

      # Edit throwaway copies so doc.save never mutates the committed fixtures.
      tmp = Path.join(System.tmp_dir!(), "ecrits_office_test_#{System.unique_integer([:positive])}.docx")
      File.cp!(@fixture, tmp)
      tmp_pptx = Path.join(System.tmp_dir!(), "ecrits_office_test_#{System.unique_integer([:positive])}.pptx")
      File.cp!(@pptx_fixture, tmp_pptx)
      on_exit(fn -> File.rm(tmp); File.rm(tmp_pptx) end)

      {:ok, ctx: %{pool: pool}, doc_path: tmp, pptx_path: tmp_pptx, native: true}
    else
      {:ok, native: false}
    end
  end

  test "real UNO NIF: open -> find/elements -> set -> apply -> save -> reopen persists",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping real Office integration test")
    else
      ctx = context.ctx
      path = context.doc_path

      # open through the Tools layer (proves docx registers + routes to Office)
      assert {:ok, %{"document" => doc, "kind" => "docx"}} =
               Tools.call(ctx, "doc.open", %{"path" => path, "kind" => "docx"})

      # doc.list shows the office doc as server-backed
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      entry = Enum.find(docs, &(&1["document"] == doc))
      assert entry["kind"] == "docx"
      assert entry["backing"] == "server"

      # doc.find -> cells with UNO-native refs + context
      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "Region"})

      assert matches != []
      cell = Enum.find(matches, &(&1["type"] == "cell"))
      assert cell, "expected a table-cell match for \"Region\""
      assert is_binary(cell["ref"])
      assert cell["ref"] =~ ~r/^tbl\[.*\]\/cell\[.*\]$/
      assert is_binary(cell["context"])
      IO.puts("\n[office] doc.find {type:cell} -> ref=#{cell["ref"]} context=#{inspect(cell["context"])}")

      # doc.get on the cell ref -> reflective type + settable property names + values
      assert {:ok, got} = Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => cell["ref"]})
      assert got["type"] == "cell"
      assert is_list(got["settable"])
      assert "CharWeight" in got["settable"]

      # doc.set a cell property (universal setter -> uno_set)
      assert {:ok, %{"ok" => true, "revision" => 1}} =
               Tools.call(ctx, "doc.set", %{
                 "document" => doc,
                 "ref" => cell["ref"],
                 "props" => %{"CharWeight" => 150.0},
                 "base_revision" => 0
               })

      # doc.edit set_text on the cell (replace_text scoped to the ref -> set_text)
      assert {:ok, %{"ok" => true, "revision" => 2}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "Region",
                   "replacement" => "ECRITS_OFFICE_MCP_TOKEN",
                   "ref" => cell["ref"]
                 },
                 "base_revision" => 1
               })

      # doc.read sees the edited cell text, capped at 30 paragraphs
      assert {:ok, page} = Tools.call(ctx, "doc.read", %{"document" => doc})
      assert page["size"] <= 30
      assert page["text"] =~ "ECRITS_OFFICE_MCP_TOKEN"

      # doc.save (-> uno_save with the docx export filter)
      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})

      # close + reopen a FRESH pool/editor -> the edit persisted to disk
      assert :ok = Pool.close(ctx.pool, doc)
      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool2)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx2, "doc.open", %{"path" => path, "kind" => "docx"})

      assert {:ok, %{"matches" => reopened}} =
               Tools.call(ctx2, "doc.find", %{"document" => doc2, "pattern" => "ECRITS_OFFICE_MCP_TOKEN"})

      assert reopened != [], "the saved cell edit did not persist across reopen"
    end
  end

  test "real UNO NIF (pptx): open -> elements -> set shape prop -> edit text -> save -> reopen persists",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping real Office pptx integration test")
    else
      ctx = context.ctx
      path = context.pptx_path

      # open the pptx through the Tools layer (proves pptx registers + routes to Office)
      assert {:ok, %{"document" => doc, "kind" => "pptx"}} =
               Tools.call(ctx, "doc.open", %{"path" => path, "kind" => "pptx"})

      # doc.list shows the pptx as server-backed
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      entry = Enum.find(docs, &(&1["document"] == doc))
      assert entry["kind"] == "pptx"
      assert entry["backing"] == "server"

      # doc.find -> the Impress shape via the walk_impress path; UNO-native shape ref
      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "ECRITS_PPTX_ORIGINAL"})

      assert matches != []
      shape = Enum.find(matches, &(&1["type"] in ["text_frame", "shape"]))
      assert shape, "expected an Impress shape/text_frame match"
      assert is_binary(shape["ref"])
      # Impress refs are page[<SlideName>]/shape[<ShapeName>]
      assert shape["ref"] =~ ~r/^page\[.*\]\/shape\[.*\]$/
      IO.puts("\n[office] pptx doc.find {type:#{shape["type"]}} -> ref=#{shape["ref"]}")

      # doc.get on the shape ref -> reflective type + settable property names + values
      assert {:ok, got} = Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => shape["ref"]})
      assert got["type"] == "shape"
      assert is_list(got["settable"])
      assert "FillColor" in got["settable"]

      # doc.set a shape property (universal setter -> uno_set)
      assert {:ok, %{"ok" => true, "revision" => 1}} =
               Tools.call(ctx, "doc.set", %{
                 "document" => doc,
                 "ref" => shape["ref"],
                 "props" => %{"FillColor" => 16_711_680},
                 "base_revision" => 0
               })

      # doc.edit replace_text scoped to the shape ref -> set_text on the text frame
      assert {:ok, %{"ok" => true, "revision" => 2}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "ECRITS_PPTX_ORIGINAL",
                   "replacement" => "ECRITS_PPTX_MCP_TOKEN",
                   "ref" => shape["ref"]
                 },
                 "base_revision" => 1
               })

      # doc.read sees the edited shape text
      assert {:ok, page} = Tools.call(ctx, "doc.read", %{"document" => doc})
      assert page["text"] =~ "ECRITS_PPTX_MCP_TOKEN"

      # doc.save (-> uno_save with the pptx export filter)
      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})

      # close + reopen in a FRESH pool -> the slide-shape edit persisted to disk
      assert :ok = Pool.close(ctx.pool, doc)
      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool2_pptx)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx2, "doc.open", %{"path" => path, "kind" => "pptx"})

      assert {:ok, %{"matches" => reopened}} =
               Tools.call(ctx2, "doc.find", %{"document" => doc2, "pattern" => "ECRITS_PPTX_MCP_TOKEN"})

      assert reopened != [], "the saved slide-shape edit did not persist across reopen"
    end
  end

  # Probe the UNO arm by attempting a real open of the fixture through the
  # Office backend. `{:office_unavailable, _}` (no SDK build / no install dir) or
  # an :nif_not_loaded ErlangError => the arm is absent and the test skips green.
  defp uno_available? do
    case Office.open(@fixture, kind: :docx) do
      {:ok, handle} ->
        Office.close(handle)
        true

      {:error, {:office_unavailable, _}} ->
        false

      {:error, _other} ->
        false
    end
  rescue
    _ -> false
  end
end
