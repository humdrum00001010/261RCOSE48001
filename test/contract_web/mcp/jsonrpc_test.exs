defmodule ContractWeb.MCP.JSONRPCTest do
  use ExUnit.Case, async: true

  alias ContractWeb.MCP.JSONRPC

  describe "standard error codes" do
    test "parse_error_code is -32700" do
      assert JSONRPC.parse_error_code() == -32_700
    end

    test "invalid_request_code is -32600" do
      assert JSONRPC.invalid_request_code() == -32_600
    end

    test "method_not_found_code is -32601" do
      assert JSONRPC.method_not_found_code() == -32_601
    end

    test "invalid_params_code is -32602" do
      assert JSONRPC.invalid_params_code() == -32_602
    end

    test "internal_error_code is -32603" do
      assert JSONRPC.internal_error_code() == -32_603
    end

    test "unauthorized_code is -32000 (application-defined)" do
      assert JSONRPC.unauthorized_code() == -32_000
    end

    test "error_code/1 maps atom names to codes" do
      assert JSONRPC.error_code(:parse_error) == -32_700
      assert JSONRPC.error_code(:method_not_found) == -32_601
      assert JSONRPC.error_code(:unauthorized) == -32_000
      assert JSONRPC.error_code(:forbidden) == -32_001
    end

    test "error_code/1 falls back to internal_error for unknown atoms" do
      assert JSONRPC.error_code(:totally_made_up) == -32_603
    end
  end

  describe "parse/1" do
    test "accepts a valid request" do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/list",
        "params" => %{"foo" => "bar"}
      }

      assert {:ok, req} = JSONRPC.parse(payload)
      assert req.jsonrpc == "2.0"
      assert req.id == 7
      assert req.method == "tools/list"
      assert req.params == %{"foo" => "bar"}
    end

    test "accepts a notification (no id)" do
      payload = %{"jsonrpc" => "2.0", "method" => "ping"}
      assert {:ok, req} = JSONRPC.parse(payload)
      assert req.id == nil
      assert req.method == "ping"
    end

    test "defaults params to an empty map when missing" do
      payload = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}
      assert {:ok, req} = JSONRPC.parse(payload)
      assert req.params == %{}
    end

    test "rejects a payload missing method" do
      assert {:error, {-32_600, _}} = JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => 1})
    end

    test "rejects a payload missing jsonrpc version" do
      assert {:error, {-32_600, _}} =
               JSONRPC.parse(%{"id" => 1, "method" => "tools/list"})
    end

    test "rejects a nil payload" do
      assert {:error, {-32_600, _}} = JSONRPC.parse(nil)
    end

    test "rejects a non-map payload" do
      assert {:error, {-32_600, _}} = JSONRPC.parse("not a map")
    end
  end

  describe "parse_body/1" do
    test "parses a valid JSON binary" do
      body = ~s({"jsonrpc":"2.0","id":1,"method":"initialize"})
      assert {:ok, %{method: "initialize", id: 1}} = JSONRPC.parse_body(body)
    end

    test "returns -32700 for malformed JSON" do
      assert {:error, {-32_700, _}} = JSONRPC.parse_body(~s({not json))
    end

    test "returns -32600 for valid JSON but invalid envelope" do
      assert {:error, {-32_600, _}} = JSONRPC.parse_body(~s({"foo":"bar"}))
    end

    test "returns -32700 for non-binary input" do
      assert {:error, {-32_700, _}} = JSONRPC.parse_body(:not_binary)
    end
  end

  describe "success/2 and error_response/3" do
    test "success/2 builds the canonical shape" do
      assert JSONRPC.success(42, %{"ok" => true}) == %{
               "jsonrpc" => "2.0",
               "id" => 42,
               "result" => %{"ok" => true}
             }
    end

    test "error_response/3 builds the canonical shape" do
      assert JSONRPC.error_response(7, -32_601, "Method not found") == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{"code" => -32_601, "message" => "Method not found"}
             }
    end

    test "error_response/4 attaches `data` when provided" do
      assert JSONRPC.error_response(1, -32_602, "bad", %{"field" => "x"}) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32_602, "message" => "bad", "data" => %{"field" => "x"}}
             }
    end

    test "error_response/3 omits `data` when nil" do
      env = JSONRPC.error_response(1, -32_602, "bad")
      refute Map.has_key?(env["error"], "data")
    end
  end

  describe "from_gateway_error/2" do
    test "maps :unknown_tool to method_not_found" do
      env = JSONRPC.from_gateway_error(1, {:unknown_tool, "foo.bar"})
      assert env["error"]["code"] == -32_601
      assert env["error"]["message"] =~ "foo.bar"
    end

    test "maps :forbidden to -32001" do
      env = JSONRPC.from_gateway_error(1, :forbidden)
      assert env["error"]["code"] == -32_001
    end

    test "maps :unauthorized to -32000" do
      env = JSONRPC.from_gateway_error(1, :unauthorized)
      assert env["error"]["code"] == -32_000
    end

    test "maps :missing_document_id to invalid_params" do
      env = JSONRPC.from_gateway_error(1, :missing_document_id)
      assert env["error"]["code"] == -32_602
    end

    test "maps :invalid_query and :invalid_text to invalid_params" do
      assert JSONRPC.from_gateway_error(1, :invalid_query)["error"]["code"] == -32_602
      assert JSONRPC.from_gateway_error(1, :invalid_text)["error"]["code"] == -32_602
    end

    test "maps {:invalid_action, errors} to invalid_params with data" do
      env = JSONRPC.from_gateway_error(1, {:invalid_action, %{kind: ["can't be blank"]}})
      assert env["error"]["code"] == -32_602
      assert env["error"]["data"] == %{kind: ["can't be blank"]}
    end

    test "maps anything else to tool_failure -32002" do
      env = JSONRPC.from_gateway_error(1, :wat)
      assert env["error"]["code"] == -32_002
    end
  end
end
