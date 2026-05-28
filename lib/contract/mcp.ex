defmodule Contract.MCP do
  @moduledoc """
  MCP resource and tool surface for Contract Studio.

  This module owns the v0.5 MCP contract shape. It delegates durable document
  mutations to `Contract.Runtime` via `Contract.Command` and gates reads through
  owner ACL before exposing projections as MCP resources.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Change
  alias Contract.Agent.Document, as: AgentDocument
  alias Contract.Command
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime

  @doc_read_default_size 5
  @doc_read_max_size 10

  def expanded_tool_descriptors do
    agent_doc_tool_descriptors()
  end

  # Agent-facing tool surface used by Contract.Agent.Document
  # over an authenticated MCP route_ref). These are deliberately opinionated:
  # the model gets short, positional args and only the RHWP-backed edit path.
  defp agent_doc_tool_descriptors do
    [
      %{
        "name" => "doc.get",
        "description" =>
          "Aggregate metadata-only document handle. Returns revision, title/type, and counts. No read contract, outline, index, cursors, pages, paragraph refs, table refs, text, field values, table cell text, edit targets, or alternate index modes.",
        "inputSchema" =>
          object_schema(
            %{
              "since_revision" => %{"type" => "integer", "minimum" => 0}
            },
            []
          )
      },
      %{
        "name" => "doc.read",
        "description" =>
          "Read a bounded logical paragraph/leaf window for one section. Inputs are `sec`, `at`, and optional `size`; default size is 5. Output contains revision, coordinates, text, chars, and next_at only. For `doc.write` `insert_at_offset`, compute a zero-based character offset inside the returned item text. No UI envelope or edit targets.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "at" => %{"type" => "integer", "minimum" => 0},
              "size" => %{"type" => "integer", "minimum" => 1, "maximum" => @doc_read_max_size}
            },
            ["sec", "at"]
          )
      },
      %{
        "name" => "doc.write",
        "description" =>
          "Document write intent. Shape: `{sec, para, type, payload, base_revision}`. `type` is substrate family; currently `paragraph`. `payload` is `{cmd, payload}` with paragraph commands `insert_after_match`, `insert_before_match`, `insert_at_offset`, and `insert_paragraph_after`. Matches resolve exactly and uniquely inside current paragraph text. If a match is ambiguous, fail closed; reread the paragraph and use `insert_at_offset` with an exact zero-based character offset from doc.read text. Output contains revision only.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "type" => %{"type" => "string", "enum" => ["paragraph"]},
              "payload" => %{
                "type" => "object",
                "properties" => %{
                  "cmd" => %{
                    "type" => "string",
                    "enum" => [
                      "insert_after_match",
                      "insert_before_match",
                      "insert_at_offset",
                      "insert_paragraph_after"
                    ]
                  },
                  "payload" => %{"type" => "object"}
                },
                "required" => ["cmd", "payload"]
              },
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["sec", "para", "type", "payload", "base_revision"]
          )
      }
    ]
  end

  # MCP protocol versions we implement. We speak Streamable HTTP
  # (single `/mcp` POST endpoint, SSE-or-JSON response framing), which
  # is the "2025-03-26" revision. The older "2024-11-05" wire is also
  # compatible because Streamable HTTP is a strict superset of the
  # earlier dual-endpoint SSE protocol from the server's perspective.
  @supported_mcp_versions ~w(2025-03-26 2024-11-05)

  @doc """
  Returns the MCP initialize result payload.

  Echoes the client's requested `protocolVersion` when it's one we
  support; otherwise advertises the newest version we implement
  (`2025-03-26`). OpenAI's hosted MCP runner upgraded to
  `2025-03-26` — replying with the older `2024-11-05` made their
  client treat the catalog as unreachable and surface
  `external_connector_error / Http status code: 424 (Failed
  Dependency)`.
  """
  def initialize(payload) do
    requested =
      case payload do
        %{"protocolVersion" => v} when is_binary(v) -> v
        %{protocolVersion: v} when is_binary(v) -> v
        _ -> nil
      end

    version =
      if requested in @supported_mcp_versions, do: requested, else: "2025-03-26"

    %{
      "protocolVersion" => version,
      "serverInfo" => %{"name" => "contract-studio", "version" => "0.5.0"},
      "capabilities" => %{
        "tools" => %{"listChanged" => false},
        "resources" => %{"listChanged" => false}
      }
    }
  end

  @doc "Expanded v0.5 tool names."
  def expanded_tool_names, do: Enum.map(expanded_tool_descriptors(), & &1["name"])

  @doc "Returns the complete MCP tools/list payload."
  def list_tools(_ctx, _route_ref), do: %{"tools" => Gateway.tools_descriptor()}

  @doc "Resources were pruned with the legacy DB-backed MCP surface."
  def list_resources(%Context{}, _route_ref), do: %{"resources" => []}

  def list_resources(_ctx, _route_ref), do: %{"resources" => []}

  @doc "Resource reads were pruned with the legacy DB-backed MCP surface."
  def read_resource(%Context{}, _route_ref, uri) when is_binary(uri), do: {:error, :invalid_uri}

  def read_resource(_ctx, _route_ref, _uri), do: {:error, :invalid_uri}

  @doc "Calls an MCP tool by name. Mutating document tools emit Commands."

  # --- agent-facing doc.* tools ---------------------------------------------
  def call_tool(%Context{} = ctx, route_ref, "doc.get" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           :ok <- reject_doc_get_type(args),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        since = Map.get(args, "since_revision") || Map.get(args, :since_revision)

        cond do
          is_integer(since) and since >= state.revision ->
            {:ok, %{"revision" => state.revision}}

          true ->
            with :ok <- ensure_positional_index(document_id, state) do
              build_doc_get_response(state, args)
            end
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.get", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.read" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, sec} <- fetch_required_int(args, "sec"),
           {:ok, at} <- fetch_required_int(args, "at"),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        size =
          fetch_int(args, "size") |> bounded_limit(@doc_read_default_size, @doc_read_max_size)

        read =
          state
          |> Contract.MCP.Projection.read_window(sec, at, size)
          |> Map.put("revision", state.revision)

        {:ok, read}
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.read", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.write" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, canonical_args} <- normalize_doc_write_args(args),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        case existing_mcp_change(route_ref, document_id, canonical_args, "write") do
          {:ok, change} ->
            with :ok <- ensure_doc_write_materialized(document_id, change) do
              {:ok, mcp_change_payload(change)}
            end

          :miss ->
            with :ok <- ensure_doc_write_basis_materialized(document_id, state),
                 {:ok, resolved_args} <- resolve_doc_write_args(canonical_args, state) do
              submit_doc_write(ctx, route_ref, document_id, resolved_args, canonical_args)
            end
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.write", _args), do: {:error, :forbidden}

  def call_tool(_ctx, _route_ref, tool, _args), do: {:error, {:unknown_tool, tool}}

  defp ensure_positional_index(document_id, %Runtime.State{} = state) do
    case Contract.MCP.Projection.current_snapshot_revision(state) do
      revision when is_integer(revision) and revision >= state.revision ->
        :ok

      _ ->
        case Contract.RhwpSnapshot.Materializer.ensure_committed(document_id, state.revision) do
          {:ok, %{revision: revision}} when is_integer(revision) and revision >= state.revision ->
            :ok

          {:ok, _} ->
            {:error, {:positional_index_unavailable, :stale_ack}}

          {:error, reason} ->
            {:error, {:positional_index_unavailable, reason}}
        end
    end
  end

  # Agent-facing doc.get response. The projection is loaded only to derive
  # aggregate counts; concrete navigation/content stays behind doc.read.
  defp build_doc_get_response(%Runtime.State{} = state, _args) do
    ir = Contract.MCP.Projection.to_agent_ir(state)
    index = Contract.MCP.Projection.positional_index(ir)

    {:ok,
     %{
       "revision" => state.revision,
       "d" => ir["title"],
       "t" => ir["contract_type"],
       "counts" => %{
         "pages" => length(index["pages"] || []),
         "sections" => length(ir["sections"] || []),
         "paragraphs" => Contract.MCP.Projection.paragraph_count(ir),
         "logical_leaves" => logical_leaf_count(ir, index),
         "table_controls" => length(index["table_controls"] || []),
         "grid_table_controls" => index["grid_table_controls"] || 0,
         "single_cell_table_controls" => index["single_cell_table_controls"] || 0,
         "table_cells" => index["table_cell_count"] || 0
       }
     }}
  end

  defp reject_doc_get_type(args) when is_map(args) do
    case Map.get(args, "type") || Map.get(args, :type) do
      nil -> :ok
      _ -> {:error, {:invalid_params, "doc.get is metadata-only and does not accept type"}}
    end
  end

  defp reject_doc_get_type(_args), do: {:error, {:invalid_params, "arguments must be an object"}}

  defp logical_leaf_count(%{"sections" => sections}, index) when is_list(sections) do
    table_paragraphs =
      sections
      |> Enum.flat_map(&Map.get(&1, "paragraphs", []))
      |> Enum.count(&(&1["kind"] == "table"))

    Contract.MCP.Projection.paragraph_count(%{"sections" => sections}) - table_paragraphs +
      (index["table_cell_count"] || 0)
  end

  defp logical_leaf_count(_ir, index), do: index["table_cell_count"] || 0

  defp bounded_limit(value, default, max_value) do
    cond do
      not is_integer(value) -> default
      value < 1 -> default
      true -> min(value, max_value)
    end
  end

  defp authorize_route_ref(nil, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: nil}, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: document_id}, document_id), do: :ok
  defp authorize_route_ref(%RouteRef{}, _document_id), do: {:error, :forbidden}

  defp authorize_command(ctx, route_ref, %Command{document_id: document_id})
       when is_binary(document_id) do
    with :ok <- authorize_route_ref(route_ref, document_id),
         do: Gateway.authorize_document(ctx, document_id)
  end

  defp authorize_command(_ctx, _route_ref, %Command{}), do: :ok

  defp build_command(%Context{} = ctx, nil, raw), do: build_command(ctx, %RouteRef{}, raw)

  defp build_command(%Context{} = ctx, route_ref, raw) when is_map(raw) do
    attrs = %{
      kind: parse_command_kind(Map.get(raw, "kind") || Map.get(raw, :kind)),
      document_id:
        Map.get(raw, "document_id") || Map.get(raw, :document_id) || route_ref.document_id,
      chat_thread_id:
        Map.get(raw, "chat_thread_id") || Map.get(raw, :chat_thread_id) ||
          route_ref.chat_thread_id,
      agent_run_id: route_ref_agent_run_id(route_ref),
      actor_type:
        parse_actor_type(Map.get(raw, "actor_type") || Map.get(raw, :actor_type) || "user"),
      actor_id: Map.get(raw, "actor_id") || Map.get(raw, :actor_id) || user_id(ctx),
      base_revision:
        Map.get(raw, "base_revision") || Map.get(raw, :base_revision) || route_ref.base_revision,
      idempotency_key:
        Map.get(raw, "idempotency_key") || Map.get(raw, :idempotency_key) ||
          "mcp-#{System.unique_integer([:positive])}",
      payload: Map.get(raw, "payload") || Map.get(raw, :payload) || %{},
      message: Map.get(raw, "message") || Map.get(raw, :message)
    }

    changeset = Command.changeset(%Command{}, attrs)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, {:invalid_action, errors_on(changeset)}}
    end
  end

  defp build_command(_ctx, _route_ref, _raw), do: {:error, :invalid_action_payload}

  defp route_ref_agent_run_id(%RouteRef{agent_run_id: run_id}) when is_binary(run_id),
    do: run_id

  defp route_ref_agent_run_id(_route_ref), do: nil

  defp parse_command_kind(value), do: parse_enum(value, Ecto.Enum.values(Command, :kind))
  defp parse_actor_type(value), do: parse_enum(value, Ecto.Enum.values(Command, :actor_type))

  defp parse_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: value
  end

  defp parse_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp parse_enum(_value, _allowed), do: nil

  # --- agent doc.* helpers --------------------------------------------------

  # Wraps a doc.* handler invocation with two PubSub broadcasts on
  # `agent:#{run_id}`: a :tool_call_started before the handler runs, and a
  # :tool_call_completed (or :tool_call_failed) after. This is what the
  # chat-rail consumes to render tool_call cards — independent of OpenAI's
  # SSE event vocabulary (which varies across model versions).
  defp instrumented(route_ref, tool, args, fun) when is_function(fun, 0) do
    run_id = route_ref && Map.get(route_ref, :agent_run_id)
    thread_id = route_ref && Map.get(route_ref, :chat_thread_id)
    tool_id = "#{tool}-#{System.unique_integer([:positive])}"

    if is_binary(run_id) do
      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        "agent:#{run_id}",
        {:tool_call_started, run_id,
         %{
           id: tool_id,
           name: tool,
           server_label: "contract-doc",
           arguments: args
         }}
      )
    end

    result =
      try do
        fun.()
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      end

    {status, payload, summary} =
      case result do
        {:ok, output} -> {"completed", output, tool_call_summary(output)}
        {:error, reason} -> {"failed", %{"error" => inspect(reason)}, short_error(reason)}
      end

    operation = doc_tool_operation(tool_id, tool, status, run_id, args, payload, summary)

    # PubSub for live UI.
    if is_binary(run_id) do
      tag = if status == "completed", do: :tool_call_completed, else: :tool_call_failed

      payload_msg =
        if status == "completed" do
          Map.put(operation, "output", payload)
        else
          operation
        end

      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        "agent:#{run_id}",
        {tag, run_id, tool_id, payload_msg}
      )
    end

    # Durable: write to chat_thread so the bubble re-renders on reload.
    Contract.ChatThreads.append_tool_call_message(thread_id, operation)

    result
  end

  defp doc_tool_operation(tool_id, tool, "failed", run_id, _args, %{"error" => error}, _summary) do
    %{
      "id" => tool_id,
      "name" => tool,
      "agent_run_id" => run_id,
      "error" => error
    }
  end

  defp doc_tool_operation(tool_id, tool, status, run_id, args, payload, summary) do
    %{
      "id" => tool_id,
      "type" => "tool_call",
      "name" => tool,
      "tool_name" => tool,
      "raw_name" => tool,
      "server_label" => "contract-doc",
      "title" => tool,
      "status" => status,
      "summary" => summary,
      "agent_run_id" => run_id,
      "details" => %{
        "arguments" => args,
        "output" => payload
      }
    }
  end

  defp tool_call_summary(%{"revision" => rev}) when is_integer(rev), do: "rev #{rev}"
  defp tool_call_summary(%{"unchanged" => true, "revision" => rev}), do: "rev #{rev} (no change)"
  defp tool_call_summary(%{"ok" => false, "error" => err}), do: to_string(err)
  defp tool_call_summary(_), do: "ok"

  defp short_error({:forbidden, reason}), do: "forbidden: #{reason}"
  defp short_error({code, _}) when is_atom(code), do: Atom.to_string(code)
  defp short_error(code) when is_atom(code), do: Atom.to_string(code)
  defp short_error(_), do: "error"

  # Strict gate for doc.* tools. Caller MUST hold a route_ref that:
  #   (a) carries scope "agent_doc" (blocks slack/api tokens from escalating)
  #   (b) resolves to an Agent.Document attempt that is still alive. Nil
  #       agent_run_id is not accepted for this agent-owned surface; public
  #       and legacy document tools keep their existing non-agent behavior.
  defp authorize_doc_mcp(%RouteRef{scopes: scopes} = ref) when is_list(scopes) do
    with :ok <- check_agent_doc_scope(scopes),
         :ok <- check_run_alive(ref) do
      :ok
    end
  end

  defp authorize_doc_mcp(_route_ref), do: {:error, {:forbidden, :no_route_ref}}

  defp check_agent_doc_scope(scopes) do
    if "agent_doc" in Enum.map(scopes, &to_string/1) do
      :ok
    else
      {:error, {:forbidden, :missing_scope_agent_doc}}
    end
  end

  defp check_run_alive(%RouteRef{agent_run_id: nil}),
    do: {:error, {:forbidden, :run_not_active}}

  defp check_run_alive(%RouteRef{
         agent_run_id: run_id,
         user_id: user_id,
         document_id: document_id
       })
       when is_binary(run_id) and is_binary(user_id) and is_binary(document_id) do
    case AgentDocument.active_attempt(user_id, document_id) do
      {:ok, %{run_id: ^run_id}} ->
        :ok

      {:ok, %{run_id: _other_run_id}} ->
        {:error, {:forbidden, :run_not_active}}

      nil ->
        check_run_registered(run_id)
    end
  end

  defp check_run_alive(%RouteRef{agent_run_id: run_id}) when is_binary(run_id) do
    check_run_registered(run_id)
  end

  defp check_run_registered(run_id) do
    case AgentDocument.whereis(run_id) do
      pid when is_pid(pid) -> :ok
      _ -> {:error, {:forbidden, :run_not_active}}
    end
  end

  # Stricter sibling of authorize_route_ref/2: refuses tokens that lack a
  # document_id binding (the legacy clause treats `nil → :ok` as a god
  # token; we never want that for doc.* mutation tools).
  defp authorize_route_ref_strict(%RouteRef{document_id: doc_id}, doc_id)
       when is_binary(doc_id),
       do: :ok

  defp authorize_route_ref_strict(%RouteRef{}, _doc_id),
    do: {:error, {:forbidden, :route_ref_doc_mismatch}}

  defp authorize_route_ref_strict(_route_ref, _doc_id),
    do: {:error, {:forbidden, :no_route_ref}}

  defp resolve_document_id(route_ref, args) do
    explicit = Map.get(args, "document_id") || Map.get(args, :document_id)

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      match?(%RouteRef{document_id: id} when is_binary(id), route_ref) ->
        {:ok, route_ref.document_id}

      true ->
        {:error, :missing_document_id}
    end
  end

  defp actor_type_for(%RouteRef{agent_run_id: id}) when is_binary(id), do: "agent"
  defp actor_type_for(_), do: "user"

  defp mcp_idempotency_key(nil, tool, args) do
    "mcp-#{tool}-#{:erlang.phash2(args)}-#{System.unique_integer([:positive])}"
  end

  defp mcp_idempotency_key(run_id, tool, args) do
    "mcp:#{run_id}:#{tool}:#{:erlang.phash2(args)}"
  end

  defp existing_mcp_change(%RouteRef{agent_run_id: run_id}, document_id, args, applied)
       when is_binary(run_id) and is_binary(document_id) do
    key = mcp_idempotency_key(run_id, applied, args)

    case Repo.get_by(Change, document_id: document_id, idempotency_key: key) do
      %Change{command_kind: "doc_write"} = change ->
        {:ok, change}

      %Change{command_kind: :doc_write} = change ->
        {:ok, change}

      _ ->
        :miss
    end
  end

  defp existing_mcp_change(_route_ref, _document_id, _args, _applied), do: :miss

  defp mcp_change_payload(%Change{} = change) do
    %{"revision" => change.result_revision}
  end

  defp normalize_doc_write_args(args) when is_map(args) do
    with {:ok, sec} <- fetch_required_int(args, "sec"),
         {:ok, para} <- fetch_required_int(args, "para"),
         {:ok, type} <- fetch_required_string(args, "type"),
         {:ok, base_revision} <- fetch_required_int(args, "base_revision"),
         {:ok, payload} <- fetch_required_map(args, "payload"),
         {:ok, cmd} <- fetch_required_string(payload, "cmd"),
         {:ok, inner_payload} <- fetch_required_map(payload, "payload") do
      if type == "paragraph" do
        {:ok,
         %{
           "sec" => sec,
           "para" => para,
           "type" => type,
           "base_revision" => base_revision,
           "payload" => %{"cmd" => cmd, "payload" => stringify_keys(inner_payload)}
         }}
      else
        {:error, {:not_supported, "doc.write type=#{type} is not supported"}}
      end
    end
  end

  defp normalize_doc_write_args(_args),
    do: {:error, {:invalid_params, "arguments must be an object"}}

  defp resolve_doc_write_args(
         %{
           "sec" => sec,
           "para" => para,
           "type" => "paragraph",
           "payload" => %{"cmd" => cmd, "payload" => payload}
         } = args,
         %Runtime.State{} = state
       )
       when cmd in ["insert_after_match", "insert_before_match"] do
    with {:ok, paragraph_text} <- paragraph_text_for_write(state, sec, para),
         {:ok, match} <- fetch_required_string(payload, "match"),
         {:ok, _text} <- fetch_required_string(payload, "text"),
         {:ok, match_start} <- unique_match_offset(paragraph_text, match) do
      off =
        case cmd do
          "insert_after_match" -> match_start + String.length(match)
          "insert_before_match" -> match_start
        end

      {:ok, Map.put(args, "resolved", %{"off" => off})}
    end
  end

  defp resolve_doc_write_args(
         %{
           "sec" => sec,
           "para" => para,
           "type" => "paragraph",
           "payload" => %{"cmd" => "insert_paragraph_after", "payload" => payload}
         } = args,
         %Runtime.State{} = state
       ) do
    with {:ok, paragraph_text} <- paragraph_text_for_write(state, sec, para),
         {:ok, _text} <- fetch_required_string(payload, "text") do
      {:ok, Map.put(args, "resolved", %{"off" => String.length(paragraph_text)})}
    end
  end

  defp resolve_doc_write_args(
         %{
           "sec" => sec,
           "para" => para,
           "type" => "paragraph",
           "payload" => %{"cmd" => "insert_at_offset", "payload" => payload}
         } = args,
         %Runtime.State{} = state
       ) do
    with {:ok, paragraph_text} <- paragraph_text_for_write(state, sec, para),
         {:ok, off} <- fetch_required_int(payload, "off"),
         :ok <- validate_insert_offset(paragraph_text, off),
         {:ok, _text} <- fetch_required_string(payload, "text") do
      {:ok, Map.put(args, "resolved", %{"off" => off})}
    end
  end

  defp resolve_doc_write_args(
         %{"type" => "paragraph", "payload" => %{"cmd" => cmd}},
         %Runtime.State{}
       ),
       do: {:error, {:invalid_params, "unsupported doc_write command #{inspect(cmd)}"}}

  defp paragraph_text_for_write(%Runtime.State{} = state, sec, para) do
    case Contract.MCP.Projection.paragraph_text_at(state, sec, para) do
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, {:invalid_params, "paragraph not found at sec=#{sec}, para=#{para}"}}
    end
  end

  defp unique_match_offset(text, match) do
    offsets = match_offsets(text, match)

    case offsets do
      [offset] -> {:ok, offset}
      [] -> {:error, {:invalid_params, "match not found in paragraph"}}
      _ -> {:error, {:invalid_params, "match is ambiguous in paragraph"}}
    end
  end

  defp validate_insert_offset(text, off) when is_integer(off) do
    if off <= String.length(text) do
      :ok
    else
      {:error, {:invalid_params, "off is outside paragraph bounds"}}
    end
  end

  defp validate_insert_offset(_text, _off),
    do: {:error, {:invalid_params, "off (integer) is required"}}

  defp match_offsets(text, match) do
    text_graphemes = String.graphemes(text)
    match_graphemes = String.graphemes(match)
    match_len = length(match_graphemes)
    max_start = length(text_graphemes) - match_len

    if match_len == 0 or max_start < 0 do
      []
    else
      for idx <- 0..max_start,
          Enum.slice(text_graphemes, idx, match_len) == match_graphemes,
          do: idx
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp fetch_int(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp fetch_required_int(args, key) do
    case fetch_int(args, key) do
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, {:invalid_params, "#{key} (integer) is required"}}
    end
  end

  defp fetch_required_string(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  defp fetch_required_map(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp submit_doc_write(ctx, route_ref, document_id, args, idempotency_args) do
    run_id = route_ref && Map.get(route_ref, :agent_run_id)

    command_args = %{
      "kind" => "doc_write",
      "document_id" => document_id,
      "actor_type" => actor_type_for(route_ref),
      "actor_id" => user_id(ctx) || (route_ref && Map.get(route_ref, :user_id)),
      "agent_run_id" => run_id,
      "base_revision" => Map.fetch!(args, "base_revision"),
      "idempotency_key" => mcp_idempotency_key(run_id, "write", idempotency_args),
      "payload" => Map.drop(args, ["base_revision"])
    }

    with {:ok, command} <- build_command(ctx, route_ref, command_args),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, %Contract.Change{} = change} <- Runtime.apply(ctx, command),
         :ok <- ensure_doc_write_materialized(document_id, change) do
      {:ok, %{"revision" => change.result_revision}}
    end
  end

  defp ensure_doc_write_basis_materialized(document_id, %Runtime.State{} = state) do
    case Contract.MCP.Projection.validate_text_edit_basis(state) do
      :ok ->
        :ok

      {:error, {:invalid_params, "same-revision projection basis" <> _}} ->
        with {:ok, opts} <- repair_materialization_opts(document_id, state.revision),
             :ok <- request_doc_materialization(document_id, state.revision, opts),
             :ok <- Contract.MCP.Projection.validate_text_edit_basis(state) do
          :ok
        end

      error ->
        error
    end
  end

  defp ensure_doc_write_materialized(document_id, %Change{result_revision: revision} = change)
       when is_binary(document_id) and is_integer(revision) do
    if rhwp_materialized_change?(document_id, change) do
      :ok
    else
      opts =
        case repair_materialization_opts(document_id, revision) do
          {:ok, repair_opts} -> repair_opts
          _ -> [text_events: text_events_for_change(change)]
        end

      with :ok <- request_doc_materialization(document_id, revision, opts) do
        if rhwp_materialized_change?(document_id, change) do
          :ok
        else
          {:error, {:materialization_unavailable, :missing_materialized_text}}
        end
      end
    end
  end

  defp ensure_doc_write_materialized(_document_id, _change), do: :ok

  defp request_doc_materialization(document_id, revision, opts) do
    case Contract.RhwpSnapshot.Materializer.ensure_committed(document_id, revision, opts) do
      {:ok, %{revision: ack_revision}}
      when is_integer(ack_revision) and ack_revision >= revision ->
        :ok

      {:ok, _} ->
        {:error, {:materialization_unavailable, :stale_ack}}

      {:error, reason} ->
        {:error, {:materialization_unavailable, reason}}
    end
  end

  defp repair_materialization_opts(document_id, revision)
       when is_binary(document_id) and is_integer(revision) do
    with %Contract.RhwpSnapshot.Record{} = latest <-
           Contract.RhwpSnapshot.latest_for_document(document_id),
         true <- is_integer(latest.revision) and latest.revision >= revision,
         %Contract.RhwpSnapshot.Record{} = previous <- repair_base_rhwp_snapshot(latest),
         events when events != [] <-
           text_events_between(
             document_id,
             previous.revision,
             latest_materialization_revision(document_id, revision)
           ) do
      {:ok,
       [text_events: events, base_snapshot: materialization_base_snapshot(document_id, previous)]}
    else
      _ -> {:error, :no_repair_materialization}
    end
  end

  defp repair_materialization_opts(_document_id, _revision),
    do: {:error, :no_repair_materialization}

  defp latest_materialization_revision(document_id, revision) do
    case Contract.Store.latest_revision(document_id) do
      {:ok, latest_revision} when is_integer(latest_revision) and latest_revision > revision ->
        latest_revision

      _ ->
        revision
    end
  end

  defp previous_rhwp_snapshot(%Contract.RhwpSnapshot.Record{
         document_id: document_id,
         revision: revision,
         format: format
       })
       when is_binary(document_id) and is_integer(revision) do
    Repo.one(
      from s in Contract.RhwpSnapshot.Record,
        where: s.document_id == ^document_id and s.format == ^format and s.revision < ^revision,
        order_by: [desc: s.revision],
        limit: 1
    )
  end

  defp previous_rhwp_snapshot(_snapshot), do: nil

  defp repair_base_rhwp_snapshot(%Contract.RhwpSnapshot.Record{
         document_id: document_id,
         revision: revision,
         format: format
       })
       when is_binary(document_id) and is_integer(revision) do
    Repo.one(
      from s in Contract.RhwpSnapshot.Record,
        where: s.document_id == ^document_id and s.format == ^format and s.revision < ^revision,
        order_by: [asc: s.revision],
        limit: 1
    )
  end

  defp repair_base_rhwp_snapshot(snapshot), do: previous_rhwp_snapshot(snapshot)

  defp text_events_between(document_id, after_revision, through_revision)
       when is_binary(document_id) and is_integer(after_revision) and is_integer(through_revision) do
    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind in ["edit_text", "doc_write"] and
            c.result_revision > ^after_revision and c.result_revision <= ^through_revision,
        order_by: [asc: c.result_revision, asc: c.inserted_at, asc: c.id]
    )
    |> Enum.flat_map(&text_events_for_change/1)
  end

  defp text_events_between(_document_id, _after_revision, _through_revision), do: []

  defp materialization_base_snapshot(document_id, %Contract.RhwpSnapshot.Record{} = snapshot) do
    projection = snapshot.projection || %{}

    %{
      url: "/documents/#{document_id}/rhwp-snapshots/#{snapshot.revision}.#{snapshot.format}",
      revision: snapshot.revision,
      lamport: snapshot_lamport(projection),
      contractTypeKey: snapshot_string(projection, "contract_type"),
      templatePath: snapshot_string(projection, "template_path")
    }
  end

  defp snapshot_lamport(projection) when is_map(projection) do
    case Map.get(projection, "lamport") || Map.get(projection, :lamport) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp snapshot_lamport(_projection), do: nil

  defp snapshot_string(projection, key) when is_map(projection) do
    case Map.get(projection, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp snapshot_string(_projection, _key), do: nil

  defp rhwp_materialized_change?(document_id, %Change{result_revision: revision} = change) do
    case Contract.RhwpSnapshot.latest_for_document(document_id) do
      %{revision: snapshot_revision, projection: projection}
      when is_integer(snapshot_revision) and snapshot_revision >= revision and is_map(projection) ->
        events = text_events_for_change(change)

        events != [] and materialized_text_basis_valid?(document_id) and
          (structural_text_events?(events) or
             Enum.all?(events, &snapshot_covers_text_event?(projection, &1)))

      _ ->
        false
    end
  end

  defp materialized_text_basis_valid?(document_id) do
    with {:ok, %Runtime.State{} = state} <- Contract.Store.load(document_id),
         :ok <- Contract.MCP.Projection.validate_text_edit_basis(state) do
      true
    else
      _ -> false
    end
  end

  defp structural_text_events?(events) do
    Enum.any?(events, &(Map.get(&1, "kind") in ["insert_paragraph", "merge_paragraph"]))
  end

  defp snapshot_covers_text_event?(projection, %{"kind" => "insert_text"} = event) do
    with sec when is_integer(sec) <- Map.get(event, "sec"),
         para when is_integer(para) <- Map.get(event, "para"),
         off when is_integer(off) <- Map.get(event, "off"),
         text when is_binary(text) and text != "" <- Map.get(event, "text"),
         paragraph_text when is_binary(paragraph_text) <-
           snapshot_paragraph_text(projection, sec, para) do
      String.slice(paragraph_text, off, String.length(text)) == text
    else
      _ -> false
    end
  end

  defp snapshot_covers_text_event?(_projection, _event), do: false

  defp snapshot_paragraph_text(%{"sections" => sections}, sec, para) when is_list(sections) do
    with %{} = section <- Enum.find(sections, &(map_int(&1, "idx") == sec)),
         paragraphs when is_list(paragraphs) <- Map.get(section, "paragraphs"),
         %{} = paragraph <- Enum.find(paragraphs, &(map_int(&1, "idx") == para)) do
      Map.get(paragraph, "text")
    else
      _ -> nil
    end
  end

  defp snapshot_paragraph_text(_projection, _sec, _para), do: nil

  defp map_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp text_events_for_change(%Change{} = change) do
    change.payload
    |> List.wrap()
    |> Enum.flat_map(&change_payload_to_text_event(&1, change))
  end

  defp change_payload_to_text_event(%{"op" => op, "args" => args}, %Change{} = change)
       when is_map(args) do
    [
      args
      |> Map.put("kind", to_string(op))
      |> Map.put("revision", change.result_revision)
      |> maybe_put_event_id(change.idempotency_key)
    ]
  end

  defp change_payload_to_text_event(%{op: op, args: args}, %Change{} = change)
       when is_map(args) do
    [
      args
      |> stringify_keys()
      |> Map.put("kind", to_string(op))
      |> Map.put("revision", change.result_revision)
      |> maybe_put_event_id(change.idempotency_key)
    ]
  end

  defp change_payload_to_text_event(_, _change), do: []

  defp maybe_put_event_id(event, event_id) when is_binary(event_id) and event_id != "",
    do: Map.put(event, "event_id", event_id)

  defp maybe_put_event_id(event, _event_id), do: event

  defp user_id(%Context{user: %{id: id}}), do: id
  defp user_id(_ctx), do: nil

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp object_schema(properties, required) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end
end
