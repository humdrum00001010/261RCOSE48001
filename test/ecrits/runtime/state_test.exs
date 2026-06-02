defmodule Ecrits.Runtime.StateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Runtime.State

  test "default struct has empty projection with all top-level keys" do
    s = %State{}
    assert s.revision == 0
    assert s.document_id == nil

    for key <- [:title, :type_key, :metadata, :nodes, :node_order, :fields, :marks, :refs] do
      assert Map.has_key?(s.projection, key), "projection missing key #{inspect(key)}"
    end

    assert s.projection.nodes == %{}
    assert s.projection.node_order == []
    assert s.projection.refs == %{}
  end

  test "empty_projection/0 returns the same value as the default" do
    assert %State{}.projection == State.empty_projection()
  end

  # ----------------------------------------------------------------------------
  # IR-richness (task #37): table/cell node attrs.
  # ----------------------------------------------------------------------------

  describe "IR-richness: table + cell attrs" do
    test "table/cell attr_keys advertise the canonical HWPX-grade fields" do
      table_keys = State.table_attr_keys()

      for k <- [:column_widths, :border_fill_id, :header_row_count, :footer_row_count] do
        assert k in table_keys
      end

      cell_keys = State.cell_attr_keys()

      for k <- [
            :row_span,
            :col_span,
            :border_fill_id,
            :vertical_alignment,
            :padding_top,
            :padding_right,
            :padding_bottom,
            :padding_left
          ] do
        assert k in cell_keys
      end
    end

    test "table + cell nodes round-trip through projection with their rich attrs" do
      table = %{
        id: "tbl-1",
        kind: :table,
        children: ["c1"],
        attrs: %{
          column_widths: [3000, 4000, 5000],
          border_fill_id: "5",
          header_row_count: 1,
          footer_row_count: 0
        }
      }

      cell = %{
        id: "c1",
        kind: :cell,
        attrs: %{
          row_span: 2,
          col_span: 3,
          border_fill_id: "7",
          vertical_alignment: :center,
          padding_top: 100,
          padding_right: 200,
          padding_bottom: 300,
          padding_left: 400
        }
      }

      proj =
        State.empty_projection()
        |> Map.put(:nodes, %{"tbl-1" => table, "c1" => cell})
        |> Map.put(:node_order, ["tbl-1"])

      state = %State{document_id: "d", revision: 0, projection: proj}

      tbl_attrs = state.projection.nodes["tbl-1"].attrs
      assert tbl_attrs.column_widths == [3000, 4000, 5000]
      assert tbl_attrs.border_fill_id == "5"
      assert tbl_attrs.header_row_count == 1
      assert tbl_attrs.footer_row_count == 0

      cell_attrs = state.projection.nodes["c1"].attrs
      assert cell_attrs.row_span == 2
      assert cell_attrs.col_span == 3
      assert cell_attrs.border_fill_id == "7"
      assert cell_attrs.vertical_alignment == :center
      assert cell_attrs.padding_top == 100
      assert cell_attrs.padding_right == 200
      assert cell_attrs.padding_bottom == 300
      assert cell_attrs.padding_left == 400
    end

    test "absent rich attrs are simply missing — projection shape is additive" do
      table = %{id: "t", kind: :table, children: [], attrs: %{rows: 1, cols: 1}}
      proj = State.empty_projection() |> Map.put(:nodes, %{"t" => table})
      state = %State{document_id: "d", revision: 0, projection: proj}

      attrs = state.projection.nodes["t"].attrs
      refute Map.has_key?(attrs, :column_widths)
      refute Map.has_key?(attrs, :border_fill_id)
      assert attrs.rows == 1
      assert attrs.cols == 1
    end
  end
end
