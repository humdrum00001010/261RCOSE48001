defmodule Ecrits.Doc.MCPServerAgentContextTest do
  @moduledoc """
  The MCP-isolation resolution (Phase 2): `Ecrits.Doc.MCPServer.handle_call_tool/3`
  takes the `_agent_id` the per-agent url's plug splices into the tool arguments,
  resolves it via `Ecrits.Workspace.Session.fetch_agent/1` to the live agent session,
  and dispatches the tool in THAT agent's document context (its own active doc) —
  never a global active doc. An unknown/dead agent id is rejected.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.MCPServer
  alias Ecrits.AcpAgent.Session, as: AgentSession

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    prev_vfs = Application.get_env(:ecrits, :doc_vfs)
    Application.put_env(:ecrits, :doc_vfs, enabled: false)

    on_exit(fn ->
      restore(:ehwp, :runtime, prev)
      restore(:ecrits, :doc_vfs, prev_vfs)
    end)

    :ok
  end

  # Start a headless agent session (no provider turn needed; we only read its
  # tool_context), bound to `pool_document_id`.
  defp start_agent(id, pool_document_id, opts) do
    start_supervised!(
      {AgentSession,
       id: id,
       ctx: nil,
       provider: %{id: "codex"},
       exmcp_adapter: EcritsWeb.FakeAcpAdapter,
       adapter_opts: [exmcp_adapter: EcritsWeb.FakeAcpAdapter],
       workspace_root: File.cwd!(),
       document_path: Keyword.get(opts, :document_path),
       pool_document_id: pool_document_id,
       mcp_servers: []},
      id: {:agent, id}
    )
  end

  defp call_tool(name, args) do
    {:ok, state} = MCPServer.init([])
    MCPServer.handle_call_tool(name, args, state)
  end

  test "an unknown agent id is rejected (agent_not_found), tool never runs" do
    assert {:ok, %{content: [content], isError: true}, _state} =
             call_tool("doc.context", %{"_agent_id" => "nope-not-real"})

    assert %{"error" => "agent_not_found", "agent_id" => "nope-not-real"} =
             Jason.decode!(content.text)
  end

  test "doc.context exposes the UI-selected document path even before a pool id is active" do
    id = "fg-path-#{System.unique_integer([:positive])}"
    start_agent(id, nil, document_path: "drafts/current.hwpx")

    assert {:ok, %{content: [content]}, _} = call_tool("doc.context", %{"_agent_id" => id})

    assert %{"current_document" => current} = decoded = Jason.decode!(content.text)
    assert Map.keys(decoded) == ["current_document"]

    assert current == %{
             "document" => "drafts/current.hwpx",
             "name" => "current.hwpx",
             "kind" => "hwpx",
             "path" => "drafts/current.hwpx",
             "backing" => nil,
             "active" => true
           }
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
