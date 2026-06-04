defmodule EcritsWeb.Plugs.DocToolsMCPPlug do
  @moduledoc """
  Mounts the `Ecrits.Doc.MCPServer` (the `doc.*` MCP server) at `/mcp/doc-tools`,
  exposing it over the MCP **streamable-HTTP** transport.

  Installed in `EcritsWeb.Endpoint` *before* `Plug.Parsers` so the underlying
  `ExMCP.HttpPlug` reads the raw JSON-RPC body itself (Phoenix's parser would
  otherwise consume it). Requests outside the mount prefix pass through
  untouched.

  The provider subprocess (codex app-server / claude CLI) reaches this in-process
  BEAM MCP server over streamable HTTP at `http://<host>:<port>/mcp/doc-tools`.

  ## Why we handle the SSE GET ourselves

  Codex's Rust MCP client (`rmcp`) implements the streamable-HTTP transport by
  POSTing JSON-RPC requests *and* opening a long-lived `GET` SSE stream on the
  same endpoint for server→client messages. The handshake fails unless that GET
  succeeds.

  `ExMCP.HttpPlug`'s built-in SSE path cannot serve it here: its `SSEHandler`
  runs as a separate `GenServer` and calls `Plug.Conn.chunk/2` from that process,
  but Bandit requires chunks to be written by the process that owns the
  connection (the request process). The result is a hard crash
  (`"Adapter functions must be called by stream owner"`) and an empty stream, so
  codex's client never completes its handshake.

  Because the `doc.*` tools are a pure request/response surface (every response
  comes back on the POST that asked for it — we never need to push
  server-initiated notifications), the GET SSE only needs to *stay open*. We
  therefore serve it directly from the request process here: open the
  `text/event-stream`, advertise the session id, and emit periodic keepalive
  comments until the client disconnects. POST/DELETE/OPTIONS keep delegating to
  `ExMCP.HttpPlug`, whose POST channel already works correctly.
  """

  @behaviour Plug

  import Plug.Conn

  @prefix ["mcp", "doc-tools"]

  # Codex's rmcp client probes RFC 9728 / RFC 8414 OAuth discovery endpoints for
  # the MCP server before connecting. With OAuth disabled these 404, but the
  # probes codex issues against the *origin* root (e.g.
  # `/.well-known/oauth-authorization-server/mcp/doc-tools`) fall outside our
  # mount and would otherwise raise `Phoenix.Router.NoRouteError`. We answer them
  # here with a clean 404 JSON so the agent silently proceeds unauthenticated.
  @well_known_oauth ["oauth-authorization-server", "oauth-protected-resource"]

  # Keepalive cadence for the idle SSE channel. Comment frames (`: ...`) keep
  # intermediaries and the client from treating the stream as dead without being
  # interpreted as MCP messages.
  @keepalive_interval_ms 15_000

  @impl true
  def init(_opts) do
    # SSE is disabled on the delegated `ExMCP.HttpPlug` because its SSEHandler is
    # incompatible with Bandit (see moduledoc). We serve the streamable-HTTP GET
    # SSE channel ourselves; the POST request/response channel is delegated.
    ExMCP.HttpPlug.init(
      handler: Ecrits.Doc.MCPServer,
      server_info: %{name: "ecrits-doc-tools", version: "0.1.0"},
      sse_enabled: false,
      cors_enabled: true
    )
  end

  @impl true
  def call(%Plug.Conn{path_info: @prefix ++ rest} = conn, mcp_opts) do
    conn
    |> Map.put(:path_info, rest)
    |> Map.put(:script_name, conn.script_name ++ @prefix)
    |> dispatch(mcp_opts)
    |> Plug.Conn.halt()
  end

  # OAuth discovery probes codex issues at the origin root for this MCP server:
  #   GET /.well-known/oauth-authorization-server[/mcp/doc-tools]
  #   GET /.well-known/oauth-protected-resource[/mcp/doc-tools]
  # Answer with 404 JSON (OAuth is not enabled) instead of leaking to the router.
  def call(%Plug.Conn{method: "GET", path_info: [".well-known", kind | rest]} = conn, _mcp_opts)
      when kind in @well_known_oauth do
    if rest == [] or rest == @prefix do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "Not found"}))
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  def call(conn, _mcp_opts), do: conn

  # The streamable-HTTP SSE channel: a GET that accepts `text/event-stream`. We
  # own this in the request process so `chunk/2` is legal under Bandit.
  defp dispatch(%Plug.Conn{method: "GET"} = conn, _mcp_opts) do
    if accepts_event_stream?(conn) do
      serve_sse(conn)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "Not found"}))
    end
  end

  # Everything else (POST JSON-RPC, DELETE session teardown, OPTIONS preflight)
  # is handled correctly by the delegated streamable-HTTP plug.
  defp dispatch(conn, mcp_opts), do: ExMCP.HttpPlug.call(conn, mcp_opts)

  defp accepts_event_stream?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp serve_sse(conn) do
    session_id = session_id(conn)

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("mcp-session-id", session_id)
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    # An opening comment establishes the stream immediately (some clients wait
    # for the first byte before considering the SSE connected).
    case chunk(conn, ": ecrits-doc-tools stream open\n\n") do
      {:ok, conn} -> keepalive_loop(conn)
      {:error, _reason} -> conn
    end
  end

  # Block in the request process, emitting keepalive comments until the client
  # disconnects (chunk returns an error) or the connection is closed. This keeps
  # the streamable-HTTP GET channel alive for the lifetime of the MCP session
  # without ever needing to push a server-initiated message.
  defp keepalive_loop(conn) do
    receive do
    after
      @keepalive_interval_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> keepalive_loop(conn)
          {:error, _reason} -> conn
        end
    end
  end

  # Reuse the client-provided session id when present (per MCP spec the client
  # echoes the id the server handed out on the POST initialize); otherwise mint
  # one so the GET response always advertises a stable session.
  defp session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> "sse_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
    end
  end
end
