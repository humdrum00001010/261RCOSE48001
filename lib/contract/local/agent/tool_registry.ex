defmodule Contract.Local.Agent.ToolRegistry do
  @moduledoc """
  Local document tool registry for provider-agnostic agent sessions.

  Tools operate only against the active local document session supplied by the
  caller. The registry does not reach into hosted MCP or RHWP internals.
  """

  alias Contract.Local.Agent.DocumentTools

  @namespace "positionalindex"
  @read_tool @namespace <> ".read"
  @find_tool @namespace <> ".find"
  @write_tool @namespace <> ".write"

  @tools [
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" =>
        "Read a compact paragraph window from the active local RHWP PositionalIndex. Defaults: sec=0, at=0, size=5.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "sec" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "at" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "size" => %{"type" => "integer", "minimum" => 1, "maximum" => 10, "default" => 5}
        }
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "find",
      "description" =>
        "doc.find(pattern, sec?, at?, size?, case_sensitive?): regex search over active local RHWP PositionalIndex paragraphs. Omit sec to search all sections. Returns matches with sec, para, off, count, and text; use off/count directly with doc.write replace_range.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "Regex pattern to match against paragraph text."
          },
          "sec" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Optional section index. Omit to search all sections."
          },
          "at" => %{
            "type" => "integer",
            "minimum" => 0,
            "default" => 0,
            "description" => "Zero-based match cursor from a prior next_at."
          },
          "size" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10},
          "case_sensitive" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "When false, regex matching uses case-insensitive Unicode mode."
          }
        },
        "required" => ["pattern"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "write",
      "description" =>
        "doc.write applies bounded paragraph text edits through the live PositionalIndex. No start/end args exist. For replace_range pass payload.cmd=\"replace_range\" and payload.payload={off, count, text}; off/count are grapheme offsets, suitable for values returned by doc.find.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "sec" => %{"type" => "integer", "minimum" => 0},
          "para" => %{"type" => "integer", "minimum" => 0},
          "type" => %{"type" => "string", "enum" => ["paragraph"]},
          "payload" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "cmd" => %{
                "type" => "string",
                "enum" => [
                  "insert_after_match",
                  "insert_before_match",
                  "insert_at_offset",
                  "insert_paragraph_after",
                  "replace_range",
                  "replace_paragraph"
                ]
              },
              "payload" => %{
                "type" => "object",
                "additionalProperties" => false,
                "description" =>
                  "Command-specific payload. replace_range uses off, count, text; never use start/end.",
                "properties" => %{
                  "match" => %{
                    "type" => "string",
                    "minLength" => 1,
                    "description" =>
                      "Exact paragraph substring for insert_after_match or insert_before_match."
                  },
                  "off" => %{
                    "type" => "integer",
                    "minimum" => 0,
                    "description" =>
                      "Grapheme offset in paragraph. Required by insert_at_offset and replace_range."
                  },
                  "count" => %{
                    "type" => "integer",
                    "minimum" => 0,
                    "description" =>
                      "Grapheme count to replace/delete. Required by replace_range; use doc.find count."
                  },
                  "text" => %{
                    "type" => "string",
                    "minLength" => 1,
                    "description" =>
                      "Text to insert. Required by every write command; for replace_range this is replacement text."
                  }
                }
              }
            },
            "required" => ["cmd", "payload"]
          },
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["sec", "para", "type", "payload", "base_revision"]
      },
      "annotations" => %{"readOnlyHint" => false}
    }
  ]

  @doc "Provider-facing local document tools."
  def tools, do: @tools

  def tool_names, do: Enum.map(@tools, &canonical_name/1)

  @doc "Returns true when policy requires approval before a tool call runs."
  def requires_approval?(policy, tool_name) do
    case normalize_policy(policy) do
      :never -> false
      :always -> true
      :on_write -> tool_risk(tool_name) == "write"
    end
  end

  @doc "Calls a local document tool against the active document session."
  def call(session, @read_tool, args),
    do: call_document_session(session, :read, normalize_args(args))

  def call(session, @find_tool, args),
    do: call_document_session(session, :find, normalize_args(args))

  def call(session, @write_tool, args),
    do: call_document_session(session, :write, normalize_args(args))

  def call(_session, tool_name, _args), do: {:error, {:unknown_tool, tool_name}}

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_args), do: %{}

  defp call_document_session(session, op, args) when is_map(session) do
    target = Map.get(session, :document_session)
    module = Map.get(session, :document_session_module)
    timeout = Map.get(session, :document_session_timeout, 5_000)
    document_id = Map.get(session, :document_id)

    cond do
      op == :write and not write_allowed?(session) ->
        {:error,
         {:write_denied,
          "Document write is disabled for read-only access. Switch workspace chat access to Ask or Full workspace."}}

      is_atom(module) and not is_nil(module) and not is_nil(target) ->
        call_document_session_module(module, target, op, args)

      is_binary(document_id) and document_id != "" ->
        call_document_session_module(DocumentTools, {:document_id, document_id}, op, args)

      is_pid(target) ->
        call_document_session_pid(target, op, args, timeout)

      true ->
        {:error, :missing_document_session}
    end
  end

  defp call_document_session(_session, _op, _args), do: {:error, :missing_document_session}

  defp write_allowed?(session) when is_map(session) do
    case normalize_access_control(Map.get(session, :access_control)) do
      :read_only -> false
      :ask -> true
      :full_workspace -> true
      :unknown -> false
    end
  end

  defp write_allowed?(_session), do: false

  defp normalize_access_control(access)
       when access in [:ask, "ask", :on_write, "on_write"],
       do: :ask

  defp normalize_access_control(access)
       when access in [
              :full_workspace,
              "full_workspace",
              "full-workspace",
              :workspace_write,
              "workspace_write",
              "workspace-write"
            ],
       do: :full_workspace

  defp normalize_access_control(access)
       when access in [:read_only, "read_only", "read-only", "readonly"],
       do: :read_only

  defp normalize_access_control(_access), do: :unknown

  defp call_document_session_module(module, target, op, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, op, 2) do
      module
      |> apply(op, [target, args])
      |> normalize_reply()
    else
      {:error, {:unsupported_document_session_api, module, op}}
    end
  end

  defp call_document_session_pid(pid, op, args, timeout) do
    ref = make_ref()
    send(pid, {:local_agent_tool_call, self(), ref, op, args})

    receive do
      {^ref, reply} -> normalize_reply(reply)
    after
      timeout -> {:error, :document_session_timeout}
    end
  end

  defp normalize_reply({:ok, _} = ok), do: ok
  defp normalize_reply({:error, _} = error), do: error
  defp normalize_reply(other), do: {:ok, other}

  defp normalize_policy(policy) when policy in [:never, :always, :on_write], do: policy
  defp normalize_policy("never"), do: :never
  defp normalize_policy("always"), do: :always
  defp normalize_policy("on_write"), do: :on_write
  defp normalize_policy(_policy), do: :never

  defp tool_risk(tool_name) do
    @tools
    |> Enum.find(&(canonical_name(&1) == tool_name))
    |> case do
      nil -> "unknown"
      tool -> tool["risk"]
    end
  end

  defp canonical_name(%{"namespace" => namespace, "name" => name})
       when is_binary(namespace) and is_binary(name),
       do: namespace <> "." <> name

  defp canonical_name(%{"name" => name}) when is_binary(name), do: name
end
