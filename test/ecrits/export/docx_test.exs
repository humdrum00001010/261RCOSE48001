defmodule Ecrits.Export.DOCXTest do
  @moduledoc """
  Smoke test for the pandoc-backed DOCX renderer. Tagged
  `:requires_pandoc` — excluded from the default suite. Run on the
  sprite (with `apt-get install -y pandoc`) via:

      mix test --include requires_pandoc
  """
  use ExUnit.Case, async: true

  alias Ecrits.Export.DOCX
  alias Ecrits.Runtime.State

  defp empty_state do
    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: State.empty_projection()
    }
  end

  defp five_paragraph_state do
    nodes =
      for i <- 1..5 do
        %{id: "p#{i}", kind: :paragraph, content: "Paragraph #{i} body."}
      end

    nodes_map = Map.new(nodes, fn n -> {n.id, n} end)
    order = Enum.map(nodes, & &1.id)

    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes_map,
          node_order: order,
          title: "Five-paragraph fixture"
      }
    }
  end

  # --------------------------------------------------------------------
  # default-suite tests (no pandoc needed)
  # --------------------------------------------------------------------

  test "returns an explicit error when pandoc is unavailable" do
    assert {:error, reason} =
             DOCX.render(empty_state(),
               pandoc_path: "/nonexistent/pandoc-binary-9d12b4f6"
             )

    assert match?(:pandoc_not_found, reason) or
             match?({:pandoc_missing, _}, reason),
           "unexpected reason: #{inspect(reason)}"
  end

  # --------------------------------------------------------------------
  # shelling smoke test (skipped by default)
  # --------------------------------------------------------------------

  @tag :requires_pandoc
  test "renders a valid DOCX (ZIP-magic) binary for a 5-paragraph fixture" do
    state = five_paragraph_state()

    assert {:ok, docx} = DOCX.render(state)
    assert is_binary(docx)
    # ZIP local file header magic: "PK\003\004"
    assert <<"PK", 0x03, 0x04, _rest::binary>> = docx
    assert byte_size(docx) > 500

    # Verify the ZIP contains the required OOXML entry.
    {:ok, handle} = :zip.zip_open(docx, [:memory])
    {:ok, list} = :zip.zip_list_dir(handle)
    :zip.zip_close(handle)

    names =
      list
      |> Enum.flat_map(fn
        {:zip_file, name, _info, _comment, _offset, _csize} -> [IO.iodata_to_binary(name)]
        _ -> []
      end)

    assert "word/document.xml" in names,
           "expected `word/document.xml` in DOCX, got: #{inspect(names)}"
  end
end
