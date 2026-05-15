defmodule Contract.Export.RendererTest do
  use ExUnit.Case, async: true

  alias Contract.Export.Renderer
  alias Contract.Runtime.State

  defp empty_state do
    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: State.empty_projection()
    }
  end

  # ---- 1-arg legacy form ---------------------------------------------------

  test "render/1 stub returns a stub body for non-HWPX formats" do
    assert {:ok, body, "text/markdown"} =
             Renderer.render(%{document_id: "x", format: :md})

    assert body =~ "EXPORT-STUB"
    assert body =~ "format=md"
    assert body =~ "document=x"
  end

  # ---- 3-arg typed form ----------------------------------------------------

  test "render/3 :hwpx dispatches to HWPX writer with content-type" do
    assert {:ok, body, "application/hwp+zip"} = Renderer.render(empty_state(), :hwpx)
    assert <<"PK", _::binary>> = body
  end

  test "render/3 :html dispatches to HTML writer with content-type" do
    assert {:ok, body, "text/html" <> _} = Renderer.render(empty_state(), :html)
    assert String.starts_with?(body, "<!doctype html>")
  end

  test "render/3 unsupported format returns {:error, {:unsupported_format, fmt}}" do
    assert {:error, {:unsupported_format, :unknown}} =
             Renderer.render(empty_state(), :unknown)
  end

  test "render/3 :pdf surfaces chromium-missing error in the default test env" do
    # Force a path that won't resolve so we don't actually shell out.
    assert {:error, reason} =
             Renderer.render(empty_state(), :pdf,
               chromium_path: "/nonexistent/chromium-9d12b4f6"
             )

    assert match?(:chromium_not_found, reason) or match?({:chromium_missing, _}, reason)
  end

  test "render/3 :docx surfaces pandoc-missing error in the default test env" do
    assert {:error, reason} =
             Renderer.render(empty_state(), :docx,
               pandoc_path: "/nonexistent/pandoc-9d12b4f6"
             )

    assert match?(:pandoc_not_found, reason) or match?({:pandoc_missing, _}, reason)
  end

  # ---- content_type/1 -----------------------------------------------------

  test "content_type/1 covers the canonical formats" do
    assert "application/pdf" = Renderer.content_type(:pdf)
    assert "application/hwp+zip" = Renderer.content_type(:hwpx)

    assert "application/vnd.openxmlformats-officedocument.wordprocessingml.document" =
             Renderer.content_type(:docx)

    assert "text/html" <> _ = Renderer.content_type(:html)
    assert "text/markdown" = Renderer.content_type(:md)
    assert "application/octet-stream" = Renderer.content_type(:wat)
  end
end
