defmodule Contract.IO.OpenAI do
  @moduledoc """
  OpenAI Responses-API client with the Korean Law MCP tool attached by default.

  Reasoning model defaults to `gpt-5-mini` with `effort: "high"`. Streaming
  returns a `Stream` of `%{type: event_type, data: data}` maps; one-shot
  returns the parsed Response JSON.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` §1–3.
  """

  alias Contract.Types, as: T

  @behaviour Contract.IO.OpenAI.Behaviour

  @type params :: map()
  @type stream_event :: %{type: String.t(), data: map()}

  @doc """
  Streams a Responses-API completion. Returns an `Enumerable` of
  `%{type: event_type, data: data}` maps and (in `meta`) the underlying
  task pid so callers can cancel.
  """
  @impl true
  @spec stream_chat(params(), T.opts()) ::
          {:ok, %{stream: Enumerable.t(), task_pid: pid()}} | {:error, term()}
  def stream_chat(params, opts \\ []) do
    {client, request} = build_request(params, opts)

    case OpenaiEx.Responses.create(client, request, stream: true) do
      {:ok, %{body_stream: body_stream, task_pid: task_pid}} ->
        {:ok, %{stream: normalize_stream(body_stream), task_pid: task_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Issues a one-shot (non-streaming) Responses-API call. Returns the parsed
  Response JSON.
  """
  @impl true
  @spec one_shot(params(), T.opts()) :: {:ok, map()} | {:error, term()}
  def one_shot(params, opts \\ []) do
    {client, request} = build_request(params, opts)

    case OpenaiEx.Responses.create(client, request) do
      {:ok, %{} = response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Builds the canonical Korean-law MCP tool entry per `tools-connectors-mcp`.
  Exposed so the Agent can ask for the same shape when building context.
  """
  @spec law_mcp_tool(T.opts()) :: map()
  def law_mcp_tool(opts \\ []) do
    cfg = Application.fetch_env!(:contract, :law_mcp)
    oc = Keyword.get(opts, :oc) || cfg[:oc] || "openapi"
    base = Keyword.get(opts, :endpoint) || cfg[:endpoint]

    %{
      type: "mcp",
      server_label: "korean-law",
      server_url: "#{base}?oc=#{oc}",
      require_approval: "never"
    }
  end

  @doc """
  Builds the Slack-hosted MCP tool entry per Wave 6. Returns `nil` if the
  request-scoped `Contract.Context` does not have a stored Slack token
  for the user — callers should drop nils before sending the tool list.

  Write-capable tools (chat:write, reactions:write, …) are gated behind
  the Responses-API `require_approval` flag so the agent must surface an
  approval step to the user before invoking them.
  """
  @spec slack_mcp_tool(Contract.Context.t() | nil) :: map() | nil
  def slack_mcp_tool(%Contract.Context{} = ctx) do
    case Contract.Integrations.Slack.token_for(ctx) do
      {:ok, token} ->
        %{
          type: "mcp",
          server_label: "slack",
          server_url: System.get_env("SLACK_MCP_URL") || "https://mcp.slack.com/mcp",
          require_approval: %{always: %{tool_names: slack_write_tool_names()}},
          headers: %{"Authorization" => "Bearer " <> token}
        }

      {:error, _} ->
        nil
    end
  end

  def slack_mcp_tool(_), do: nil

  # --- internals ---------------------------------------------------------

  # Write-capable Slack tool names that REQUIRE user approval before
  # invocation. Derived from `SLACK_MCP_WRITE_SCOPES` — Slack MCP tool
  # names follow `slack_<verb>_<resource>` shape (see Slack's hosted MCP
  # docs); we include the conservative set that maps 1:1 to the write
  # scopes in `.env`.
  defp slack_write_tool_names do
    [
      "slack_post_message",
      "slack_update_message",
      "slack_delete_message",
      "slack_add_reaction",
      "slack_remove_reaction",
      "slack_create_channel",
      "slack_archive_channel",
      "slack_invite_to_channel",
      "slack_create_canvas",
      "slack_edit_canvas"
    ]
  end

  defp build_request(params, opts) do
    cfg = Application.fetch_env!(:contract, :openai)
    api_key = Keyword.get(opts, :api_key) || cfg[:api_key] || env!("OPENAI_API_KEY")
    base_url = Keyword.get(opts, :base_url) || cfg[:base_url] || "https://api.openai.com/v1"

    client =
      OpenaiEx.new(api_key)
      |> OpenaiEx.with_base_url(base_url)
      |> OpenaiEx.with_receive_timeout(60_000)

    extra_tools = Keyword.get(opts, :extra_tools, [])
    include_law = Keyword.get(opts, :include_law_mcp?, true)
    include_slack = Keyword.get(opts, :include_slack_mcp?, true)
    ctx = Keyword.get(opts, :ctx)

    base_tools = if include_law, do: [law_mcp_tool(opts)], else: []

    slack_tools =
      if include_slack do
        case slack_mcp_tool(ctx) do
          nil -> []
          tool -> [tool]
        end
      else
        []
      end

    tools =
      base_tools ++
        slack_tools ++ List.wrap(Map.get(params, :tools, [])) ++ List.wrap(extra_tools)

    request =
      params
      |> Map.put_new(:model, cfg[:default_model] || "gpt-5-mini")
      |> Map.put_new(:reasoning, %{effort: cfg[:reasoning_effort] || "high"})
      |> Map.put(:tools, tools)

    {client, request}
  end

  defp normalize_stream(body_stream) do
    body_stream
    |> Stream.flat_map(fn
      events when is_list(events) -> events
      event -> [event]
    end)
    |> Stream.map(&normalize_event/1)
    |> Stream.reject(&is_nil/1)
  end

  defp normalize_event(%{event: type, data: data}), do: %{type: type, data: data}

  defp normalize_event(%{data: %{"type" => type} = data}), do: %{type: type, data: data}

  defp normalize_event(%{data: data}) when is_map(data), do: %{type: "data", data: data}

  defp normalize_event(_), do: nil

  defp env!(name) do
    case System.get_env(name) do
      val when is_binary(val) and val != "" -> val
      _ -> raise "missing required env var: #{name}"
    end
  end
end
