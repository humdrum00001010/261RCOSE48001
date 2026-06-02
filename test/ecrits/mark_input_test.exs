defmodule Ecrits.MarkInputTest do
  use ExUnit.Case, async: true

  alias Ecrits.MarkInput

  test "changeset requires :intent and :source" do
    cs = MarkInput.changeset(%MarkInput{}, %{})
    refute cs.valid?
    assert List.keyfind(cs.errors, :intent, 0)
    assert List.keyfind(cs.errors, :source, 0)
  end

  test "accepts every documented intent + source combination" do
    for intent <- [:ask, :explain, :flag, :label, :link] do
      cs = MarkInput.changeset(%MarkInput{}, %{intent: intent, source: :user})
      assert cs.valid?, "#{intent} not accepted"
    end

    for source <- [:user, :agent, :lawyer, :slack, :law_mcp, :system] do
      cs = MarkInput.changeset(%MarkInput{}, %{intent: :label, source: source})
      assert cs.valid?, "#{source} not accepted"
    end
  end
end
