defmodule Contract.MCP do
  @moduledoc """
  MCP resource and tool surface for Contract Studio.

  This module owns the v0.5 MCP contract shape. It delegates durable document
  mutations to `Contract.Runtime` via `Contract.Command` and gates reads through
  owner ACL before exposing projections as MCP resources.
  """

  alias Contract.Change
  alias Contract.Agent.Document, as: AgentDocument
  alias Contract.Command
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime

  @doc_get_outline_default 12
  @doc_get_field_default 10
  @doc_get_max_page 50

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
          "Returns a bounded metadata/navigation page only — not paragraph bodies, not field values, not table cell text, and not full IR. Shape: `{revision, d, t, counts, outline, f, cursors, read}`. `outline` and `f` are paged with `outline_from`/`outline_limit` and `field_from`/`field_limit`; cursors carry the next `from`. Use `read` capabilities to choose a small `doc.read` target. Pin `since_revision` to short-circuit when nothing changed.",
        "inputSchema" =>
          object_schema(
            %{
              "since_revision" => %{"type" => "integer", "minimum" => 0},
              "outline_from" => %{"type" => "integer", "minimum" => 0},
              "outline_limit" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => @doc_get_max_page
              },
              "field_from" => %{"type" => "integer", "minimum" => 0},
              "field_limit" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => @doc_get_max_page
              }
            },
            []
          )
      },
      %{
        "name" => "doc.find",
        "description" =>
          "Search the document, including table cells, for `needle` (literal substring; no regex). Use when you already know target text. Paragraph hits are `[sec, para, off, len, before, match, after, \"paragraph\"]`; table cell hits are `[sec, para, off, len, before, match, after, \"cell\", {cell_path, target}]`. For cell hits, pass the returned `target` directly to `doc.edit` with `target.type: \"cell\"`.",
        "inputSchema" =>
          object_schema(
            %{
              "needle" => %{"type" => "string", "minLength" => 1},
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
              "context" => %{"type" => "integer", "minimum" => 0, "maximum" => 200}
            },
            ["needle"]
          )
      },
      %{
        "name" => "doc.read",
        "description" =>
          "Read one small cursor window. Paragraph range reads (`sec` + `from`/`to`) return only low-limit paragraph previews and next cursors. Paragraph reads (`sec`,`para`) return a bounded text window with `off`/`chars` continuation. Table reads are row/column windows (`row_from`/`row_limit`, `col_from`/`col_limit`) and do not dump whole tables. Single cell reads (`sec`,`para`,`row`,`col`) and field reads (`field_id`) return bounded text plus a ready `doc.edit` target.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "from" => %{"type" => "integer", "minimum" => 0},
              "to" => %{"type" => "integer", "minimum" => 0},
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
              "off" => %{"type" => "integer", "minimum" => 0},
              "chars" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000},
              "field_id" => %{"type" => "string", "minLength" => 1},
              "row" => %{"type" => "integer", "minimum" => 0},
              "col" => %{"type" => "integer", "minimum" => 0},
              "row_from" => %{"type" => "integer", "minimum" => 0},
              "row_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 3},
              "col_from" => %{"type" => "integer", "minimum" => 0},
              "col_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 3},
              "control_index" => %{"type" => "integer", "minimum" => 0}
            },
            []
          )
      },
      %{
        "name" => "doc.edit",
        "description" =>
          "Unified mutation tool. Shape: `{op, target, text?, block?, base_revision?}`. `op` is one of `replace_text`, `insert_block`, `delete_block`; omitted `op` defaults to `replace_text`. `target.type` selects the IR target shape. Text targets: paragraph `{type: \"paragraph\", sec, para, off, match? | len?}` or cell `{type: \"cell\", sec, para, cell_path, off, match? | len?}`. For table cells, use the `target` returned by `doc.read` or a cell hit from `doc.find`. Block targets are paragraph-only `{type: \"block\", sec, para}` with `block: {kind: \"paragraph\" | \"heading\" | \"list_item\", text?, level?}` for `insert_block`, or no block for `delete_block`. table structure edits are not currently supported and fail closed until the projection can materialize row/column changes. `replace_text.text` and `insert_block.block.text` are single-paragraph strings; line breaks are rejected. For multi-paragraph drafting, call `insert_block` once per paragraph and keep each block text newline-free. For text edits, STRONGLY PREFER `match` copied from doc.find/doc.read; replace the full exact existing value or paragraph, not only a label prefix. Pin `base_revision` to the value last seen.",
        "inputSchema" =>
          object_schema(
            %{
              "op" => %{
                "type" => "string",
                "enum" => ["replace_text", "insert_block", "delete_block"]
              },
              "target" => edit_target_schema(),
              "block" => edit_block_schema(),
              "text" => %{"type" => "string"},
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["target"]
          )
      }
    ]
  end

  defp edit_target_schema do
    %{
      "type" => "object",
      "properties" => %{
        "type" => %{"type" => "string", "enum" => ["paragraph", "cell", "block"]},
        "sec" => %{"type" => "integer", "minimum" => 0},
        "para" => %{"type" => "integer", "minimum" => 0},
        "off" => %{"type" => "integer", "minimum" => 0},
        "match" => %{
          "type" => "string",
          "description" =>
            "Preferred. The exact substring expected at the target offset that should be deleted before `text` is inserted."
        },
        "len" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Fallback delete length. Ignored when `match` is provided."
        },
        "cell_path" => cell_path_schema()
      },
      "required" => ["type", "sec", "para"]
    }
  end

  defp edit_block_schema do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => ["paragraph", "heading", "list_item"]
        },
        "text" => %{"type" => "string"},
        "level" => %{"type" => "integer", "minimum" => 1, "maximum" => 6}
      }
    }
  end

  defp cell_path_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "controlIndex" => %{"type" => "integer", "minimum" => 0},
          "cellIndex" => %{"type" => "integer", "minimum" => 0},
          "cellParaIndex" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["controlIndex", "cellIndex", "cellParaIndex"]
      }
    }
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
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        since = Map.get(args, "since_revision") || Map.get(args, :since_revision)

        cond do
          is_integer(since) and since >= state.revision ->
            {:ok, %{"ok" => true, "unchanged" => true, "revision" => state.revision}}

          true ->
            build_doc_get_response(state, args)
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.get", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.find" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, needle} <- fetch_required_string(args, "needle"),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        limit = fetch_int(args, "limit") || 20
        context = fetch_int(args, "context") || 30

        %{total: total, hits: hits} =
          Contract.MCP.Projection.find(state, needle, limit: limit, context: context)

        {:ok, %{"ok" => true, "revision" => state.revision, "total" => total, "hits" => hits}}
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.find", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.read" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, sec} <- read_sec(args),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        opts =
          []
          |> maybe_put_opt(:para, fetch_int(args, "para"))
          |> maybe_put_opt(:from, fetch_int(args, "from"))
          |> maybe_put_opt(:to, fetch_int(args, "to"))
          |> maybe_put_opt(:limit, fetch_int(args, "limit"))
          |> maybe_put_opt(:off, fetch_int(args, "off"))
          |> maybe_put_opt(:chars, fetch_int(args, "chars"))
          |> maybe_put_opt(:field_id, fetch_string(args, "field_id"))
          |> maybe_put_opt(:row, fetch_int(args, "row"))
          |> maybe_put_opt(:col, fetch_int(args, "col"))
          |> maybe_put_opt(:row_from, fetch_int(args, "row_from"))
          |> maybe_put_opt(:row_limit, fetch_int(args, "row_limit"))
          |> maybe_put_opt(:col_from, fetch_int(args, "col_from"))
          |> maybe_put_opt(:col_limit, fetch_int(args, "col_limit"))
          |> maybe_put_opt(:control_index, fetch_int(args, "control_index"))

        read = Contract.MCP.Projection.read(state, sec, opts)

        {:ok,
         %{
           "ok" => true,
           "revision" => state.revision,
           "read" => read
         }}
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.read", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.edit" = tool, args) do
    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        case existing_mcp_change(route_ref, document_id, args, "edit") do
          {:ok, payload} ->
            {:ok, payload}

          :miss ->
            with {:ok, ops} <- edit_ops(args, state),
                 :ok <- Contract.MCP.Projection.validate_text_edit_basis(state, ops) do
              submit_edit_text(ctx, route_ref, document_id, args, ops, "edit")
            end
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.edit", _args), do: {:error, :forbidden}

  def call_tool(_ctx, _route_ref, tool, _args), do: {:error, {:unknown_tool, tool}}

  # Agent-facing doc.get response. The full projection is loaded only to
  # derive metadata, counts, outline, and field read hints; paragraph bodies,
  # field values, table cells, and IR blobs stay behind doc.read/doc.find.
  defp build_doc_get_response(%Runtime.State{} = state, args) do
    ir = Contract.MCP.Projection.to_agent_ir(state)
    outline = Contract.MCP.Projection.outline(ir)
    fields = compact_fields(ir["fields"] || [])
    outline_from = fetch_int(args, "outline_from") || 0
    outline_limit = fetch_int(args, "outline_limit") || @doc_get_outline_default
    field_from = fetch_int(args, "field_from") || 0
    field_limit = fetch_int(args, "field_limit") || @doc_get_field_default

    {outline_page, outline_next} =
      page_slice(outline, outline_from, outline_limit, @doc_get_outline_default)

    {field_page, field_next} = page_slice(fields, field_from, field_limit, @doc_get_field_default)

    {:ok,
     %{
       "ok" => true,
       "revision" => state.revision,
       "d" => ir["title"],
       "t" => ir["contract_type"],
       "counts" => %{
         "sec" => length(ir["sections"] || []),
         "para" => Contract.MCP.Projection.paragraph_count(ir),
         "outline" => length(outline),
         "fields" => length(fields)
       },
       "outline" => outline_page,
       "f" => field_page,
       "cursors" =>
         compact(%{
           "outline" => cursor_from(outline_next),
           "fields" => cursor_from(field_next)
         }),
       "read" => read_capabilities()
     }}
  end

  defp compact_fields(fields) when is_list(fields) do
    Enum.map(fields, fn f ->
      [f["id"], f["label"], f["kind"], field_read_hint(f["position"] || %{})]
    end)
  end

  defp compact_fields(_), do: []

  defp page_slice(items, from, limit, default_limit) when is_list(items) do
    from = max(from || 0, 0)
    limit = limit |> bounded_limit(default_limit, @doc_get_max_page)
    page = Enum.slice(items, from, limit)
    next = from + length(page)
    next = if next < length(items), do: next, else: nil
    {page, next}
  end

  defp cursor_from(nil), do: nil
  defp cursor_from(from), do: %{"from" => from}

  defp bounded_limit(value, default, max_value) do
    cond do
      not is_integer(value) -> default
      value < 1 -> default
      true -> min(value, max_value)
    end
  end

  defp read_capabilities do
    %{
      "paragraph_window" => %{
        "args" => ["sec", "from", "to?", "limit?"],
        "default_limit" => 3
      },
      "paragraph" => %{
        "args" => ["sec", "para", "off?", "chars?"],
        "default_chars" => 400
      },
      "field" => %{
        "args" => ["field_id", "off?", "chars?"],
        "default_chars" => 400
      },
      "table_window" => %{
        "args" => ["sec", "para", "row_from?", "row_limit?", "col_from?", "col_limit?"],
        "default_rows" => 2,
        "default_cols" => 2
      },
      "cell" => %{
        "args" => ["sec", "para", "row", "col", "off?", "chars?"],
        "default_chars" => 400
      }
    }
  end

  defp field_read_hint(pos) when is_map(pos) do
    sec = Map.get(pos, "sec") || Map.get(pos, :sec)

    para =
      Map.get(pos, "parent_para") || Map.get(pos, :parent_para) || Map.get(pos, "para") ||
        Map.get(pos, :para)

    compact(%{
      "sec" => sec,
      "para" => para,
      "off_start" => Map.get(pos, "off_start") || Map.get(pos, :off_start),
      "off_end" => Map.get(pos, "off_end") || Map.get(pos, :off_end),
      "cell_path" => Map.get(pos, "cell_path") || Map.get(pos, :cell_path)
    })
  end

  defp field_read_hint(_pos), do: %{}

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

    # Build the persistent operation record (same shape the rail's
    # `operation_block` consumes; survives page reload via chat_threads).
    operation = %{
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

    # PubSub for live UI.
    if is_binary(run_id) do
      tag = if status == "completed", do: :tool_call_completed, else: :tool_call_failed
      payload_msg = Map.merge(operation, %{"output" => payload, "reason" => payload["error"]})

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
      %Change{command_kind: "edit_text"} = change ->
        {:ok, mcp_change_payload(change, applied)}

      %Change{command_kind: :edit_text} = change ->
        {:ok, mcp_change_payload(change, applied)}

      _ ->
        :miss
    end
  end

  defp existing_mcp_change(_route_ref, _document_id, _args, _applied), do: :miss

  defp mcp_change_payload(%Change{} = change, applied) do
    %{
      "ok" => true,
      "revision" => change.result_revision,
      "applied" => applied,
      "change_id" => change.id
    }
  end

  defp edit_ops(args, %Runtime.State{} = state) do
    case edit_operation(args) do
      "replace_text" ->
        with {:ok, normalized_args} <- normalize_replace_text_args(args) do
          edit_text_ops(normalized_args, state)
        end

      "insert_block" ->
        with {:ok, normalized_args} <- normalize_insert_block_args(args) do
          insert_block_ops(normalized_args)
        end

      "delete_block" ->
        with {:ok, normalized_args} <- normalize_delete_block_args(args) do
          with :ok <- validate_not_table_block_delete(state, normalized_args) do
            delete_block_ops(normalized_args)
          end
        end

      _ ->
        {:error, {:invalid_params, "op must be replace_text, insert_block, or delete_block"}}
    end
  end

  defp edit_operation(args) when is_map(args),
    do: Map.get(args, "op") || Map.get(args, :op) || "replace_text"

  defp edit_operation(_args), do: nil

  defp validate_not_table_block_delete(%Runtime.State{} = state, args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")

    case Contract.MCP.Projection.read(state, sec, para: para) do
      %{"type" => "table_window"} ->
        {:error,
         {:not_supported,
          "delete_block cannot delete table paragraphs until table structure projection is materialized"}}

      _ ->
        :ok
    end
  end

  defp normalize_replace_text_args(args) when is_map(args) do
    target = Map.get(args, "target") || Map.get(args, :target)
    text = Map.get(args, "text") || Map.get(args, :text) || ""

    with {:ok, target} <- require_target(target),
         {:ok, target_type} <- target_type(target),
         {:ok, base} <- normalize_edit_target(target_type, target),
         :ok <- validate_edit_text(text) do
      {:ok,
       base
       |> Map.put("text", text)
       |> maybe_put_from(args, "base_revision")
       |> maybe_put_from(args, "document_id")}
    end
  end

  defp normalize_replace_text_args(_args),
    do: {:error, {:invalid_params, "target is required"}}

  defp normalize_insert_block_args(args) when is_map(args) do
    target = Map.get(args, "target") || Map.get(args, :target)
    block = Map.get(args, "block") || Map.get(args, :block)

    with {:ok, target} <- require_target(target),
         :ok <- require_target_type(target, "block"),
         {:ok, base} <- block_target_args(target),
         {:ok, block} <- require_block(block) do
      {:ok,
       base
       |> Map.merge(block)
       |> maybe_put_from(args, "base_revision")
       |> maybe_put_from(args, "document_id")}
    end
  end

  defp normalize_insert_block_args(_args),
    do: {:error, {:invalid_params, "target is required"}}

  defp normalize_delete_block_args(args) when is_map(args) do
    target = Map.get(args, "target") || Map.get(args, :target)

    with {:ok, target} <- require_target(target),
         :ok <- require_target_type(target, "block"),
         {:ok, base} <- block_target_args(target) do
      {:ok,
       base
       |> maybe_put_from(args, "base_revision")
       |> maybe_put_from(args, "document_id")}
    end
  end

  defp normalize_delete_block_args(_args),
    do: {:error, {:invalid_params, "target is required"}}

  defp require_target(target) when is_map(target), do: {:ok, target}
  defp require_target(_target), do: {:error, {:invalid_params, "target is required"}}

  defp require_target_type(target, type) do
    case Map.get(target, "type") || Map.get(target, :type) do
      ^type -> :ok
      _ -> {:error, {:invalid_params, "target.type must be #{type}"}}
    end
  end

  defp target_type(target) do
    case Map.get(target, "type") || Map.get(target, :type) do
      "paragraph" -> {:ok, "paragraph"}
      "cell" -> {:ok, "cell"}
      _ -> {:error, {:invalid_params, "target.type must be paragraph or cell"}}
    end
  end

  defp block_target_args(target) do
    sec = fetch_int(target, "sec")
    para = fetch_int(target, "para")

    cond do
      is_nil(sec) or is_nil(para) ->
        {:error, {:invalid_params, "target.sec and target.para are required"}}

      true ->
        {:ok, %{"sec" => sec, "para" => para}}
    end
  end

  defp require_block(block) when is_map(block), do: {:ok, stringify_keys(block)}
  defp require_block(_block), do: {:error, {:invalid_params, "block is required"}}

  defp normalize_edit_target("paragraph", target) do
    with {:ok, base} <- base_edit_target(target) do
      {:ok, base |> maybe_put_from(target, "match") |> maybe_put_from(target, "len")}
    end
  end

  defp normalize_edit_target("cell", target) do
    cell_path = Map.get(target, "cell_path") || Map.get(target, :cell_path)

    cond do
      not is_list(cell_path) or cell_path == [] ->
        {:error, {:invalid_params, "target.cell_path is required for cell edits"}}

      true ->
        with {:ok, base} <- base_edit_target(target) do
          {:ok,
           base
           |> Map.put("cell_path", cell_path)
           |> maybe_put_from(target, "match")
           |> maybe_put_from(target, "len")}
        end
    end
  end

  defp base_edit_target(target) do
    sec = fetch_int(target, "sec")
    para = fetch_int(target, "para")
    off = fetch_int(target, "off")

    cond do
      is_nil(sec) or is_nil(para) or is_nil(off) ->
        {:error, {:invalid_params, "target.sec, target.para, target.off are required"}}

      true ->
        {:ok, %{"sec" => sec, "para" => para, "off" => off}}
    end
  end

  defp validate_edit_text(text) when is_binary(text), do: :ok
  defp validate_edit_text(_text), do: {:error, {:invalid_params, "text must be a string"}}

  defp maybe_put_from(map, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} ->
        Map.put(map, key, value)

      :error ->
        case Map.fetch(source, String.to_atom(key)) do
          {:ok, value} -> Map.put(map, key, value)
          :error -> map
        end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp edit_text_ops(args, %Runtime.State{} = state) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    off = fetch_int(args, "off")
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)
    match = Map.get(args, "match") || Map.get(args, :match)

    # `match` (the exact substring to delete) is preferred over a numeric
    # `len` — agents miscount Korean graphemes, surrogate pairs, and
    # whitespace. When `match` is given, the server measures its length
    # itself (in Unicode grapheme clusters via String.length/1, which
    # matches the rhwp WASM core's character counting).
    len =
      cond do
        is_binary(match) -> String.length(match)
        true -> fetch_int(args, "len")
      end

    cond do
      is_nil(sec) or is_nil(para) or is_nil(off) ->
        {:error, {:invalid_params, "sec, para, off are required"}}

      is_nil(len) ->
        {:error, {:invalid_params, "either match (preferred) or len is required"}}

      len < 0 ->
        {:error, {:invalid_params, "len must be >= 0"}}

      not is_binary(text) ->
        {:error, {:invalid_params, "text must be a string"}}

      multiline_text?(text) ->
        {:error,
         {:invalid_params,
          "replace_text.text must be a single paragraph; use insert_block once per paragraph for multi-paragraph drafting"}}

      true ->
        with :ok <- validate_not_table_host_paragraph_target(state, sec, para, cell_path),
             :ok <- validate_match_at_position(state, sec, para, off, match, cell_path),
             :ok <-
               validate_not_slot_label_prefix_replacement(
                 state,
                 sec,
                 para,
                 off,
                 match,
                 text,
                 cell_path
               ),
             :ok <-
               validate_fixed_contact_cell_replacement(
                 state,
                 sec,
                 para,
                 off,
                 len,
                 text,
                 cell_path
               ) do
          ops =
            []
            |> maybe_prepend_delete(sec, para, off, len, cell_path)
            |> maybe_prepend_insert(sec, para, off, text, cell_path)
            |> Enum.reverse()

          {:ok, ops}
        end
    end
  end

  defp validate_not_table_host_paragraph_target(_state, _sec, _para, [_ | _cell_path]), do: :ok

  defp validate_not_table_host_paragraph_target(%Runtime.State{} = state, sec, para, _cell_path) do
    case Contract.MCP.Projection.read(state, sec, para: para) do
      %{"type" => "table_window"} ->
        {:error, {:invalid_params, "table paragraphs must be edited with a cell target"}}

      _ ->
        :ok
    end
  end

  defp validate_match_at_position(_state, _sec, _para, _off, match, _cell_path)
       when not is_binary(match) or match == "",
       do: :ok

  defp validate_match_at_position(
         %Runtime.State{} = state,
         sec,
         para,
         off,
         match,
         [
           _ | _cell_path
         ] = cell_path
       ) do
    case cell_text_at_position(state, sec, para, cell_path) do
      {:ok, text} ->
        if String.slice(text, off, String.length(match)) == match do
          :ok
        else
          {:error,
           {:invalid_params,
            "match is not present at sec=#{sec}, para=#{para}, off=#{off}, cell_path=#{inspect(cell_path)}"}}
        end

      :error ->
        {:error,
         {:invalid_params,
          "table cell not found at sec=#{sec}, para=#{para}, cell_path=#{inspect(cell_path)}"}}
    end
  end

  defp validate_match_at_position(%Runtime.State{} = state, sec, para, off, match, _cell_path) do
    case Contract.MCP.Projection.paragraph_text_at(state, sec, para) do
      text when is_binary(text) ->
        if String.slice(text, off, String.length(match)) == match do
          :ok
        else
          {:error,
           {:invalid_params, "match is not present at sec=#{sec}, para=#{para}, off=#{off}"}}
        end

      _ ->
        {:error, {:invalid_params, "paragraph not found at sec=#{sec}, para=#{para}"}}
    end
  end

  defp validate_not_slot_label_prefix_replacement(
         _state,
         _sec,
         _para,
         _off,
         match,
         _replacement,
         _cell_path
       )
       when not is_binary(match) or match == "",
       do: :ok

  defp validate_not_slot_label_prefix_replacement(
         _state,
         _sec,
         _para,
         _off,
         _match,
         _replacement,
         [_ | _cell_path]
       ),
       do: :ok

  defp validate_not_slot_label_prefix_replacement(
         %Runtime.State{} = state,
         sec,
         para,
         off,
         match,
         replacement,
         _cell_path
       ) do
    case Contract.MCP.Projection.paragraph_text_at(state, sec, para) do
      paragraph when is_binary(paragraph) ->
        if unsafe_slot_label_prefix_replacement?(paragraph, off, match, replacement) do
          {:error,
           {:invalid_params,
            "unsafe slot label prefix replacement; match the full existing value/paragraph"}}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp unsafe_slot_label_prefix_replacement?(paragraph, off, match, replacement)
       when is_binary(paragraph) and is_integer(off) and is_binary(match) and
              is_binary(replacement) do
    match_len = String.length(match)
    suffix = String.slice(paragraph, off + match_len, String.length(paragraph))

    slot_label_prefix?(match) and String.trim(suffix) != "" and
      replacement_starts_with_slot_label?(replacement, match)
  end

  defp unsafe_slot_label_prefix_replacement?(_paragraph, _off, _match, _replacement), do: false

  defp slot_label_prefix?(text) when is_binary(text) do
    Regex.match?(~r/(계약\s*기간|시작\s*일|종료\s*일|날짜|일자|지급\s*기일|교부\s*일|납품\s*일자)/u, text)
  end

  defp replacement_starts_with_slot_label?(replacement, match)
       when is_binary(replacement) and is_binary(match) do
    String.starts_with?(replacement, match) or
      String.starts_with?(String.trim_leading(replacement), String.trim_leading(match))
  end

  defp validate_fixed_contact_cell_replacement(
         %Runtime.State{} = state,
         sec,
         para,
         off,
         len,
         replacement,
         [_ | _cell_path] = cell_path
       )
       when is_integer(off) and is_integer(len) and is_binary(replacement) do
    with {:ok, current_text} <- cell_text_at_position(state, sec, para, cell_path),
         true <- fixed_phone_cell?(current_text) do
      projected_text = replace_text_range(current_text, off, len, replacement)

      cond do
        not fixed_phone_cell?(projected_text) ->
          fixed_contact_cell_error()

        contains_email_address?(projected_text) ->
          fixed_contact_cell_error()

        String.length(String.trim(projected_text)) > 28 ->
          fixed_contact_cell_error()

        true ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp validate_fixed_contact_cell_replacement(
         _state,
         _sec,
         _para,
         _off,
         _len,
         _replacement,
         _cell_path
       ),
       do: :ok

  defp fixed_phone_cell?(text) when is_binary(text),
    do: Regex.match?(~r/^\s*전화\s*번호\s*[:：]/u, text)

  defp fixed_phone_cell?(_text), do: false

  defp contains_email_address?(text) when is_binary(text),
    do: Regex.match?(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu, text)

  defp contains_email_address?(_text), do: false

  defp replace_text_range(text, off, len, replacement) do
    prefix = String.slice(text, 0, off) || ""
    suffix = String.slice(text, off + len, String.length(text)) || ""
    prefix <> replacement <> suffix
  end

  defp fixed_contact_cell_error do
    {:error,
     {:invalid_params,
      "fixed phone table cell must preserve the 전화번호 label and short phone-style content; put 담당자/email in a wider field"}}
  end

  defp cell_text_at_position(%Runtime.State{} = state, sec, para, cell_path) do
    case Contract.MCP.Projection.cell_text_at_path(state, sec, para, cell_path) do
      text when is_binary(text) -> {:ok, text}
      _ -> :error
    end
  end

  defp maybe_prepend_delete(ops, sec, para, off, len, cell_path),
    do: maybe_prepend_delete(ops, sec, para, off, len, cell_path, nil)

  defp maybe_prepend_delete(ops, _sec, _para, _off, 0, _cell_path, _field_id), do: ops

  defp maybe_prepend_delete(ops, sec, para, off, len, cell_path, field_id) do
    [
      compact(%{
        "kind" => "delete_text",
        "sec" => sec,
        "para" => para,
        "parent_para" => maybe_parent_para(para, cell_path),
        "off" => off,
        "len" => len,
        "cell_path" => cell_path,
        "field_id" => field_id
      })
      | ops
    ]
  end

  defp maybe_prepend_insert(ops, sec, para, off, text, cell_path),
    do: maybe_prepend_insert(ops, sec, para, off, text, cell_path, nil)

  defp maybe_prepend_insert(ops, _sec, _para, _off, "", _cell_path, _field_id), do: ops

  defp maybe_prepend_insert(ops, sec, para, off, text, cell_path, field_id) do
    [
      compact(%{
        "kind" => "insert_text",
        "sec" => sec,
        "para" => para,
        "parent_para" => maybe_parent_para(para, cell_path),
        "off" => off,
        "text" => text,
        "cell_path" => cell_path,
        "field_id" => field_id
      })
      | ops
    ]
  end

  defp compact(map) when is_map(map),
    do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  defp maybe_parent_para(para, cell_path) when is_list(cell_path) and cell_path != [], do: para
  defp maybe_parent_para(_para, _cell_path), do: nil

  defp fetch_int(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp fetch_string(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp read_sec(args) do
    cond do
      is_binary(fetch_string(args, "field_id")) ->
        {:ok, fetch_int(args, "sec") || 0}

      true ->
        fetch_required_int(args, "sec")
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

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # doc.edit rides the Runtime :edit_text command kind. The Reducer applies the
  # rhwp text ops emitted here (insert_text/delete_text/insert_paragraph/
  # merge_paragraph); table structure changes are not exposed through MCP.
  defp submit_edit_text(ctx, route_ref, document_id, args, ops, applied) do
    run_id = route_ref && Map.get(route_ref, :agent_run_id)

    command_args = %{
      "kind" => "edit_text",
      "document_id" => document_id,
      "actor_type" => actor_type_for(route_ref),
      "actor_id" => user_id(ctx) || (route_ref && Map.get(route_ref, :user_id)),
      "agent_run_id" => run_id,
      "base_revision" => Map.get(args, "base_revision") || Map.get(args, :base_revision),
      "idempotency_key" => mcp_idempotency_key(run_id, applied, args),
      "payload" => %{"ops" => ops}
    }

    with :ok <- validate_doc_text_ops(ops),
         {:ok, command} <- build_command(ctx, route_ref, command_args),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, %Contract.Change{} = change} <- Runtime.apply(ctx, command) do
      {:ok,
       %{
         "ok" => true,
         "revision" => change.result_revision,
         "applied" => applied,
         "change_id" => change.id
       }}
    end
  end

  defp validate_doc_text_ops([]),
    do: {:error, {:invalid_params, "document mutation produced no text operations"}}

  defp validate_doc_text_ops(ops) when is_list(ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {op, idx}, _acc ->
      case validate_doc_text_op(op, idx) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_doc_text_ops(_ops),
    do: {:error, {:invalid_params, "document mutation operations must be a list"}}

  defp validate_doc_text_op(op, idx) when is_map(op) do
    case text_op_value(op, :kind) do
      "insert_text" ->
        with :ok <- require_text_position(op, idx),
             :ok <- require_non_negative_int(op, :off, idx),
             :ok <- require_non_empty_text(op, :text, idx) do
          :ok
        end

      "delete_text" ->
        with :ok <- require_text_position(op, idx),
             :ok <- require_non_negative_int(op, :off, idx),
             :ok <- require_positive_text_count(op, idx) do
          :ok
        end

      "insert_paragraph" ->
        with :ok <- require_non_negative_int(op, :sec, idx),
             :ok <- require_non_negative_int(op, :para, idx),
             :ok <- require_non_negative_int(op, :off, idx) do
          :ok
        end

      "merge_paragraph" ->
        with :ok <- require_non_negative_int(op, :sec, idx),
             :ok <- require_non_negative_int(op, :para, idx) do
          :ok
        end

      kind ->
        {:error, {:invalid_params, "unsupported document text op at #{idx}: #{inspect(kind)}"}}
    end
  end

  defp validate_doc_text_op(_op, idx),
    do: {:error, {:invalid_params, "document text op at #{idx} must be a map"}}

  defp require_text_position(op, idx) do
    with :ok <- require_non_negative_int(op, :sec, idx),
         :ok <- require_non_negative_int(op, :para, idx) do
      :ok
    end
  end

  defp require_non_negative_int(op, key, idx) do
    case text_op_value(op, key) do
      value when is_integer(value) and value >= 0 ->
        :ok

      _ ->
        {:error, {:invalid_params, "#{key} must be a non-negative integer at op #{idx}"}}
    end
  end

  defp require_non_empty_text(op, key, idx) do
    case text_op_value(op, key) do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        {:error, {:invalid_params, "#{key} must be a non-empty string at op #{idx}"}}
    end
  end

  defp require_positive_text_count(op, idx) do
    case text_op_value(op, :count) || text_op_value(op, :len) do
      value when is_integer(value) and value > 0 ->
        :ok

      _ ->
        {:error, {:invalid_params, "delete_text count must be a positive integer at op #{idx}"}}
    end
  end

  defp text_op_value(op, key) when is_map(op) and is_atom(key) do
    Map.get(op, Atom.to_string(key)) || Map.get(op, key)
  end

  defp multiline_text?(text) when is_binary(text), do: String.contains?(text, ["\n", "\r"])
  defp multiline_text?(_text), do: false

  defp insert_block_ops(args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    kind = Map.get(args, "kind") || Map.get(args, :kind)
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)
    parent_para = fetch_int(args, "parent_para")

    cond do
      is_nil(sec) or is_nil(para) ->
        {:error, {:invalid_params, "sec, para are required"}}

      kind == "table" ->
        {:error,
         {:not_supported,
          "insert_block kind=table is not currently supported until table creation has a materialized projection"}}

      kind not in ["paragraph", "heading", "list_item"] ->
        {:error, {:invalid_params, "kind must be paragraph|heading|list_item"}}

      not is_binary(text) ->
        {:error, {:invalid_params, "text must be a string"}}

      multiline_text?(text) ->
        {:error,
         {:invalid_params,
          "insert_block.block.text must be a single paragraph; call insert_block once per paragraph"}}

      true ->
        # `:insert_paragraph` splits the paragraph at `(sec, para, 0)` —
        # producing a fresh empty paragraph in front. If the caller supplied
        # `text`, follow with `:insert_text` at off=0 of the new paragraph.
        split_op =
          compact(%{
            "kind" => "insert_paragraph",
            "sec" => sec,
            "para" => para,
            "off" => 0,
            "parent_para" => parent_para,
            "cell_path" => cell_path
          })

        insert_op =
          if text == "" do
            nil
          else
            compact(%{
              "kind" => "insert_text",
              "sec" => sec,
              "para" => para,
              "off" => 0,
              "text" => text,
              "cell_path" => cell_path
            })
          end

        {:ok, Enum.reject([split_op, insert_op], &is_nil/1)}
    end
  end

  defp delete_block_ops(args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    parent_para = fetch_int(args, "parent_para")
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)

    cond do
      is_nil(sec) or is_nil(para) ->
        {:error, {:invalid_params, "sec, para are required"}}

      # Merging paragraph N back into N-1 effectively deletes paragraph N —
      # that's the rhwp primitive available today. Para 0 has no
      # predecessor, so refuse rather than emit a no-op.
      para == 0 ->
        {:error, {:invalid_params, "cannot delete the first paragraph in a section"}}

      true ->
        op =
          compact(%{
            "kind" => "merge_paragraph",
            "sec" => sec,
            "para" => para,
            "parent_para" => parent_para,
            "cell_path" => cell_path
          })

        {:ok, [op]}
    end
  end

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
