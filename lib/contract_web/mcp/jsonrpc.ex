defmodule ContractWeb.MCP.JSONRPC do
  @moduledoc """
  Minimal JSON-RPC 2.0 envelope helpers used by `ContractWeb.MCP.MCPPlug`.

  Implements the subset of JSON-RPC 2.0 that the MCP Streamable HTTP
  transport needs: parse a single request, build a single response, build a
  single error response. Batch requests are intentionally not supported (the
  MCP spec doesn't use them).
  """

  @type id :: String.t() | integer() | nil
  @type request :: %{
          jsonrpc: String.t(),
          id: id(),
          method: String.t(),
          params: map()
        }

  # Standard JSON-RPC 2.0 error codes.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # Application-defined errors (MCP-side).
  @unauthorized -32_000
  @forbidden -32_001
  @tool_failure -32_002

  @doc "Standard error codes."
  def parse_error_code, do: @parse_error
  def invalid_request_code, do: @invalid_request
  def method_not_found_code, do: @method_not_found
  def invalid_params_code, do: @invalid_params
  def internal_error_code, do: @internal_error
  def unauthorized_code, do: @unauthorized
  def forbidden_code, do: @forbidden
  def tool_failure_code, do: @tool_failure

  @doc """
  Maps an atom error name to its canonical numeric code.
  """
  @spec error_code(atom()) :: integer()
  def error_code(:parse_error), do: @parse_error
  def error_code(:invalid_request), do: @invalid_request
  def error_code(:method_not_found), do: @method_not_found
  def error_code(:invalid_params), do: @invalid_params
  def error_code(:internal_error), do: @internal_error
  def error_code(:unauthorized), do: @unauthorized
  def error_code(:forbidden), do: @forbidden
  def error_code(:tool_failure), do: @tool_failure
  def error_code(_), do: @internal_error

  @doc """
  Parses a raw decoded JSON value into a request map. Returns
  `{:ok, request}` on success, or `{:error, {code, message}}` for malformed
  requests.

  Notification requests (no `id` field) are accepted; `id` is set to `nil`
  and the caller must NOT respond.
  """
  @spec parse(term()) :: {:ok, request()} | {:error, {integer(), String.t()}}
  def parse(%{"jsonrpc" => "2.0", "method" => method} = payload) when is_binary(method) do
    {:ok,
     %{
       jsonrpc: "2.0",
       id: Map.get(payload, "id"),
       method: method,
       params: Map.get(payload, "params") || %{}
     }}
  end

  def parse(%{}), do: {:error, {@invalid_request, "Invalid Request"}}
  def parse(nil), do: {:error, {@invalid_request, "Invalid Request"}}
  def parse(_), do: {:error, {@invalid_request, "Invalid Request"}}

  @doc """
  Parses a raw binary JSON-RPC body. Returns `{:error, {-32700, ...}}` on
  decode failure, otherwise delegates to `parse/1`.
  """
  @spec parse_body(binary()) :: {:ok, request()} | {:error, {integer(), String.t()}}
  def parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, %Jason.DecodeError{}} -> {:error, {@parse_error, "Parse error"}}
      {:error, _} -> {:error, {@parse_error, "Parse error"}}
    end
  end

  def parse_body(_), do: {:error, {@parse_error, "Parse error"}}

  @doc """
  Builds a successful JSON-RPC response map.
  """
  @spec success(id(), term()) :: map()
  def success(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  @doc """
  Builds a JSON-RPC error response map.

      iex> ContractWeb.MCP.JSONRPC.error_response(7, -32601, "Method not found")
      %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }
  """
  @spec error_response(id(), integer(), String.t(), term()) :: map()
  def error_response(id, code, message, data \\ nil) do
    base = %{"code" => code, "message" => message}
    error = if data == nil, do: base, else: Map.put(base, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  @doc """
  Translates a `Gateway.mcp_tool/3` error into a JSON-RPC error response.
  """
  @spec from_gateway_error(id(), term()) :: map()
  def from_gateway_error(id, {:unknown_tool, tool}),
    do: error_response(id, @method_not_found, "Tool not found: #{tool}")

  def from_gateway_error(id, :forbidden),
    do: error_response(id, @forbidden, "Forbidden")

  def from_gateway_error(id, :unauthorized),
    do: error_response(id, @unauthorized, "Unauthorized")

  def from_gateway_error(id, :missing_document_id),
    do: error_response(id, @invalid_params, "missing document_id")

  def from_gateway_error(id, :invalid_query),
    do: error_response(id, @invalid_params, "invalid query")

  def from_gateway_error(id, :invalid_text),
    do: error_response(id, @invalid_params, "invalid text")

  def from_gateway_error(id, :invalid_params),
    do: error_response(id, @invalid_params, "invalid params")

  def from_gateway_error(id, :invalid_uri),
    do: error_response(id, @invalid_params, "invalid uri")

  def from_gateway_error(id, :not_found),
    do: error_response(id, @tool_failure, "Not found")

  def from_gateway_error(id, {:not_available, reason}),
    do: error_response(id, @tool_failure, "Not available", reason)

  def from_gateway_error(id, {:invalid_action, errors}),
    do: error_response(id, @invalid_params, "invalid action", errors)

  def from_gateway_error(id, reason),
    do: error_response(id, @tool_failure, "Tool failure", inspect(reason))
end
