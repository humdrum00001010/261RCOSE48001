defmodule Contract.IO.LiveTest do
  @moduledoc """
  Tagged integration tests that hit real OpenAI + real Korean Law MCP.

  Excluded from the default `mix test` run (see `test/test_helper.exs`).
  Run with `mix test --include live`. These require `OPENAI_API_KEY` and
  `LAW_OC` env vars to be set.
  """
  use ExUnit.Case, async: false

  @moduletag :live

  @tag :live_openai
  test "OpenAI Responses stream emits SSE events" do
    api_key = System.get_env("OPENAI_API_KEY")
    if is_nil(api_key) or api_key == "", do: flunk("OPENAI_API_KEY not set")

    # Use the real production base URL + law-mcp URL.
    original_openai = Application.get_env(:contract, :openai)
    original_law = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :openai,
      api_key: api_key,
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-5-mini",
      reasoning_effort: "high"
    )

    Application.put_env(:contract, :law_mcp,
      endpoint: "https://korean-law-mcp.fly.dev/mcp",
      oc: System.get_env("LAW_OC", "openapi")
    )

    on_exit(fn ->
      Application.put_env(:contract, :openai, original_openai)
      Application.put_env(:contract, :law_mcp, original_law)
    end)

    params = %{
      input: "Reply with the literal JSON object {\"mode\":\"edit\",\"ops\":[],\"marks\":[],\"message\":\"ok\"}.",
      text: %{format: %{type: "json_object"}}
    }

    assert {:ok, %{stream: stream, task_pid: _}} = Contract.IO.OpenAI.stream_chat(params)

    events = Enum.to_list(stream)
    types = events |> Enum.map(& &1.type) |> Enum.uniq()

    IO.puts("LIVE OPENAI SSE EVENT TYPES: #{inspect(types)}")

    assert Enum.any?(types, fn t ->
             t in ["response.created", "response.completed", "response.output_text.delta"]
           end)
  end

  @tag :live_law_mcp
  test "Korean Law MCP verify_citations confirms 민법 제390조" do
    original = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :law_mcp,
      endpoint: "https://korean-law-mcp.fly.dev/mcp",
      oc: System.get_env("LAW_OC", "openapi")
    )

    on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)

    assert {:ok, results} = Contract.IO.LawMCP.verify_citations(["민법 제390조"])
    IO.puts("LIVE LAW MCP verify_citations result: #{inspect(results)}")
    assert is_list(results)
  end
end
