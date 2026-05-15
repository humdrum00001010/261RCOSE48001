defmodule ContractWeb.MCP.RawBodyReader do
  @moduledoc """
  Endpoint-level plug that, for requests to `/mcp`, reads the raw HTTP body
  and stashes it in `conn.assigns[:mcp_raw_body]`, then short-circuits
  Plug.Parsers by setting `conn.body_params` to an empty map. This lets the
  inbound MCP plug (`ContractWeb.MCP.MCPPlug`) parse the raw JSON-RPC body
  itself — including handling malformed JSON with a `-32700` JSON-RPC error
  response instead of letting `Plug.Parsers.ParseError` turn it into a
  generic 400.

  Mounted in `ContractWeb.Endpoint` BEFORE `Plug.Parsers`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["mcp" | _]} = conn, _opts) do
    case read_full_body(conn, "") do
      {:ok, body, conn} ->
        conn
        |> assign(:mcp_raw_body, body)
        |> put_private(:plug_skip_csrf_protection, true)
        |> Map.put(:body_params, %{})

      {:error, _} ->
        # If we can't read the body at all, hand off — MCPPlug will treat
        # the empty raw body as a -32700 parse error.
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp read_full_body(conn, acc) do
    case read_body(conn, length: 10_000_000, read_length: 1_000_000) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_full_body(conn, acc <> body)
      {:error, _} = err -> err
    end
  end
end
