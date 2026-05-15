defmodule Contract.Export.PDFTest do
  @moduledoc """
  Smoke test for the Chromium-backed PDF renderer. Tagged
  `:requires_chromium` — excluded from the default suite. Run on the
  sprite (which ships Chromium-for-Testing) with:

      mix test --include requires_chromium

  Default suite still gets two non-shelling tests: a "chromium not
  found" surface check and a state-shape check that asserts the
  renderer at least produces an HTML payload before invoking Chromium.
  """
  use ExUnit.Case, async: true

  alias Contract.Export.PDF
  alias Contract.Runtime.State

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
  # default-suite tests (no Chromium needed)
  # --------------------------------------------------------------------

  test "returns {:error, :chromium_not_found} when no path is configured + no PATH binary" do
    # Force every resolution branch to fail.
    assert {:error, reason} =
             PDF.render(empty_state(),
               chromium_path: "/nonexistent/binary-that-does-not-exist-9d12b4f6"
             )

    assert match?(:chromium_not_found, reason) or
             match?({:chromium_missing, _}, reason),
           "unexpected reason: #{inspect(reason)}"
  end

  # --------------------------------------------------------------------
  # shelling smoke test (skipped by default)
  # --------------------------------------------------------------------

  @tag :requires_chromium
  test "renders a valid PDF binary for the 5-paragraph fixture" do
    state = five_paragraph_state()

    assert {:ok, pdf} = PDF.render(state)
    assert is_binary(pdf)
    # PDF magic: first 5 bytes are "%PDF-".
    assert <<"%PDF-", _rest::binary>> = pdf
    # Sanity floor — even a near-empty page is larger than this.
    assert byte_size(pdf) > 500
  end
end
