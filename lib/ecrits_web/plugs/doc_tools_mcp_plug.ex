defmodule EcritsWeb.Plugs.DocToolsMCPPlug do
  @moduledoc """
  Mounts the `Ecrits.Doc.MCPServer` (the `doc.*` MCP server) at `/mcp/doc-tools`.

  Installed in `EcritsWeb.Endpoint` *before* `Plug.Parsers` so the underlying
  `ExMCP.HttpPlug` reads the raw JSON-RPC body itself (Phoenix's parser would
  otherwise consume it). Requests outside the mount prefix pass through
  untouched.

  The provider subprocess (codex app-server / claude CLI) reaches this in-process
  BEAM MCP server over streamable HTTP at `http://<host>:<port>/mcp/doc-tools`.
  """

  @behaviour Plug

  @prefix ["mcp", "doc-tools"]

  @impl true
  def init(_opts) do
    ExMCP.HttpPlug.init(
      handler: Ecrits.Doc.MCPServer,
      server_info: %{name: "ecrits-doc-tools", version: "0.1.0"},
      sse_enabled: true,
      cors_enabled: true
    )
  end

  @impl true
  def call(%Plug.Conn{path_info: @prefix ++ rest} = conn, mcp_opts) do
    # Re-root the conn at the mount prefix so ExMCP.HttpPlug's `path_info`
    # pattern matches (`[]` for RPC POST, `["sse"]` for SSE, etc.) and halt the
    # endpoint pipeline once the MCP plug responds.
    conn
    |> Map.put(:path_info, rest)
    |> Map.put(:script_name, conn.script_name ++ @prefix)
    |> ExMCP.HttpPlug.call(mcp_opts)
    |> Plug.Conn.halt()
  end

  def call(conn, _mcp_opts), do: conn
end
