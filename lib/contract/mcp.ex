defmodule Contract.MCP do
  @moduledoc """
  MCP resource and tool surface for Contract Studio.

  This module owns the v0.5 MCP contract shape. It delegates durable document
  mutations to `Contract.Runtime` via `Contract.Command` and gates reads through
  owner ACL before exposing projections as MCP resources.
  """

  import Ecto.Query

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.EvidenceSnapshot
  alias Contract.Gateway
  alias Contract.Providers
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime
  alias Contract.SourceClaim
  alias Contract.SourceDocument

  def expanded_tool_descriptors do
    [
      %{
        "name" => "document.open",
        "description" => "Open a document and return its current state projection.",
        "inputSchema" => object_schema(%{"document_id" => string_schema()}, ["document_id"])
      },
      %{
        "name" => "document.read",
        "description" =>
          "Read a document MCP resource such as state, outline, nodes, fields, changes, revokes, or marks.",
        "inputSchema" =>
          object_schema(%{"document_id" => string_schema(), "resource" => string_schema()}, [
            "document_id"
          ])
      },
      %{
        "name" => "document.search",
        "description" => "Search documents visible to the current owner scope.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 100)}, [
            "query"
          ])
      },
      %{
        "name" => "document.submit_command",
        "description" =>
          "Normalize arguments into a Contract.Command and submit through Runtime.",
        "inputSchema" => object_schema(%{"command" => %{"type" => "object"}}, ["command"])
      },
      %{
        "name" => "document.revoke_change",
        "description" => "Emit a revoke_change Command for a document change.",
        "inputSchema" =>
          object_schema(%{"document_id" => string_schema(), "change_id" => string_schema()}, [
            "document_id",
            "change_id"
          ])
      },
      %{
        "name" => "source_document.read",
        "description" => "Read an owner-scoped source document resource.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema()}, ["source_document_id"])
      },
      %{
        "name" => "source_document.search_regions",
        "description" => "Search parsed source document regions by text.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema(), "query" => string_schema()}, [
            "source_document_id",
            "query"
          ])
      },
      %{
        "name" => "source_document.propose_claims",
        "description" =>
          "Request source-claim proposal for a source document when the source pipeline is available.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema()}, ["source_document_id"])
      },
      source_claim_tool(
        "source_document.confirm_claim",
        "Confirm a proposed source claim.",
        "source_claim_confirm"
      ),
      source_claim_tool(
        "source_document.correct_claim",
        "Correct a proposed source claim.",
        "source_claim_correct"
      ),
      source_claim_tool(
        "source_document.reject_claim",
        "Reject a proposed source claim.",
        "source_claim_reject"
      ),
      source_claim_tool(
        "source_document.link_claim_to_document",
        "Link a source claim to a working document.",
        "source_claim_link_to_document"
      ),
      %{
        "name" => "law.search",
        "description" => "Search legal provider records.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 50)}, ["query"])
      },
      %{
        "name" => "law.get_text",
        "description" => "Fetch full law text from the legal provider.",
        "inputSchema" => object_schema(%{"law_ref" => string_schema()}, ["law_ref"])
      },
      %{
        "name" => "law.search_precedents",
        "description" => "Search precedent records through the legal provider.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 50)}, ["query"])
      },
      %{
        "name" => "law.verify_citation",
        "description" => "Verify legal citations through the legal provider.",
        "inputSchema" => object_schema(%{"citation" => string_schema()}, ["citation"])
      },
      %{
        "name" => "evidence.attach_mark",
        "description" =>
          "Attach a mark to a legal evidence snapshot by emitting an add_mark Command.",
        "inputSchema" =>
          object_schema(
            %{
              "evidence_id" => string_schema(),
              "document_id" => string_schema(),
              "text" => string_schema()
            },
            ["evidence_id", "text"]
          )
      },
      %{
        "name" => "collab.ask_user",
        "description" =>
          "Request user clarification through a collaboration channel when available.",
        "inputSchema" => object_schema(%{"prompt" => string_schema()}, ["prompt"])
      },
      %{
        "name" => "collab.fetch_slack_context",
        "description" => "Fetch Slack thread context when Slack integration is available.",
        "inputSchema" => object_schema(%{"thread_id" => string_schema()}, ["thread_id"])
      }
    ]
  end

  @document_resource_kinds ["state", "outline", "nodes", "fields", "changes", "revokes", "marks"]

  @doc "Returns the MCP initialize result payload."
  def initialize(_payload) do
    %{
      "protocolVersion" => "2024-11-05",
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

  @doc "Returns concrete resources visible to the current owner scope."
  def list_resources(%Context{} = ctx, _route_ref) do
    resources =
      document_resources(ctx) ++ source_document_resources(ctx) ++ evidence_resources(ctx)

    %{"resources" => resources}
  end

  def list_resources(_ctx, _route_ref), do: %{"resources" => []}

  @doc "Reads a concrete MCP resource URI."
  def read_resource(%Context{} = ctx, route_ref, uri) when is_binary(uri) do
    cond do
      String.starts_with?(uri, "source_document://") ->
        with {:ok, id, path} <- parse_custom_uri(uri, "source_document://") do
          read_source_resource(ctx, route_ref, id, path, uri)
        end

      String.starts_with?(uri, "chat_thread://") ->
        {:error, {:not_available, "chat_thread resources are not implemented yet"}}

      String.starts_with?(uri, "tool_call://") ->
        {:error, {:not_available, "tool_call resources are not implemented yet"}}

      true ->
        case URI.parse(uri) do
          %URI{scheme: "document", host: document_id, path: path} when is_binary(document_id) ->
            read_document_resource(ctx, route_ref, document_id, normalize_path(path), uri)

          %URI{scheme: "evidence", host: evidence_id, path: path} when is_binary(evidence_id) ->
            read_evidence_resource(ctx, route_ref, evidence_id, normalize_path(path), uri)

          %URI{scheme: "export"} ->
            {:error, {:not_available, "export resources are not implemented yet"}}

          _ ->
            {:error, :invalid_uri}
        end
    end
  end

  def read_resource(_ctx, _route_ref, _uri), do: {:error, :invalid_uri}

  @doc "Calls an MCP tool by name. Mutating document tools emit Commands."
  def call_tool(ctx, route_ref, "document.open", args),
    do: call_tool(ctx, route_ref, "document.read", args)

  def call_tool(ctx, route_ref, "document.read", args) do
    with {:ok, document_id} <- fetch_arg(args, "document_id"),
         resource <- Map.get(args, "resource") || Map.get(args, :resource) || "state" do
      read_resource(ctx, route_ref, "document://#{document_id}/#{resource}")
    end
  end

  def call_tool(%Context{} = ctx, _route_ref, "document.search", args) do
    query = Map.get(args, "query") || Map.get(args, :query)
    limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 20)

    if is_binary(query) and query != "" do
      results =
        ctx
        |> Documents.search(query, limit)
        |> Enum.map(fn doc ->
          %{
            "document_id" => doc.id,
            "title" => doc.title,
            "type_key" => doc.type_key,
            "status" => atom_to_string(doc.status),
            "latest_revision" => doc.latest_revision
          }
        end)

      {:ok, %{"query" => query, "count" => length(results), "results" => results}}
    else
      {:error, :invalid_query}
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "document.submit_command", args) do
    raw = Map.get(args, "command") || Map.get(args, :command) || args

    with {:ok, command} <- build_command(ctx, route_ref, raw),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, result} <- Runtime.apply(ctx, command) do
      {:ok, render_result(result)}
    end
  end

  def call_tool(ctx, route_ref, "document.revoke_change", args) do
    raw =
      args
      |> Map.put_new("kind", "revoke_change")
      |> Map.put_new("command", nil)

    command_args = Map.get(args, "command") || Map.get(args, :command) || raw
    call_tool(ctx, route_ref, "document.submit_command", %{"command" => command_args})
  end

  def call_tool(ctx, route_ref, "source_document.read", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id") do
      read_resource(ctx, route_ref, "source_document://#{id}")
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "source_document.search_regions", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id"),
         {:ok, %SourceDocument{} = source} <- get_source_document(ctx, route_ref, id) do
      query = String.downcase(to_string(Map.get(args, "query") || Map.get(args, :query) || ""))

      regions =
        source.regions
        |> List.wrap()
        |> Enum.filter(fn region ->
          query == "" or String.contains?(String.downcase(inspect(region)), query)
        end)

      {:ok, %{"source_document_id" => id, "regions" => regions}}
    end
  end

  def call_tool(ctx, route_ref, "source_document.propose_claims", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id"),
         {:ok, _source} <- get_source_document(ctx, route_ref, id) do
      {:ok,
       not_available(
         "source_document.propose_claims",
         "source interpretation pipeline is not available yet"
       )}
    end
  end

  def call_tool(ctx, route_ref, tool, args)
      when tool in [
             "source_document.confirm_claim",
             "source_document.correct_claim",
             "source_document.reject_claim",
             "source_document.link_claim_to_document"
           ] do
    kind =
      case tool do
        "source_document.confirm_claim" -> "source_claim_confirm"
        "source_document.correct_claim" -> "source_claim_correct"
        "source_document.reject_claim" -> "source_claim_reject"
        "source_document.link_claim_to_document" -> "source_claim_link_to_document"
      end

    raw = args |> Map.put("kind", kind)

    with {:ok, command} <- build_command(ctx, route_ref, raw),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, result} <- Runtime.apply(ctx, command) do
      {:ok, render_result(result)}
    end
  end

  def call_tool(ctx, _route_ref, "law.search", args) do
    with {:ok, query} <- fetch_arg(args, "query") do
      limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 10)
      Providers.search_law(ctx, query, limit: limit)
    end
  end

  def call_tool(ctx, _route_ref, "law.get_text", args) do
    with {:ok, law_ref} <- fetch_arg(args, "law_ref") do
      Providers.get_law_text(ctx, law_ref, [])
    end
  end

  def call_tool(ctx, _route_ref, "law.search_precedents", args) do
    with {:ok, query} <- fetch_arg(args, "query") do
      limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 10)
      Providers.search_precedents(ctx, query, limit: limit)
    end
  end

  def call_tool(ctx, _route_ref, "law.verify_citation", args) do
    citation = Map.get(args, "citation") || Map.get(args, :citation) || Map.get(args, "text")

    if is_binary(citation) and citation != "" do
      Providers.verify_citation(ctx, citation, [])
    else
      {:error, :invalid_text}
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "evidence.attach_mark", args) do
    with {:ok, evidence_id} <- fetch_arg(args, "evidence_id"),
         {:ok, %EvidenceSnapshot{} = evidence} <- get_evidence(ctx, route_ref, evidence_id) do
      document_id =
        Map.get(args, "document_id") || Map.get(args, :document_id) || evidence.document_id

      text = Map.get(args, "text") || Map.get(args, :text) || "Evidence note"

      command_args = %{
        "kind" => "add_mark",
        "document_id" => document_id,
        "base_revision" => Map.get(args, "base_revision") || Map.get(args, :base_revision),
        "idempotency_key" =>
          Map.get(args, "idempotency_key") || "mcp-evidence-mark-#{evidence_id}",
        "payload" => %{
          "target_type" => "evidence",
          "target_id" => evidence_id,
          "intent" => Map.get(args, "intent") || "link",
          "text" => text,
          "data" => %{"evidence_id" => evidence_id}
        }
      }

      call_tool(ctx, route_ref, "document.submit_command", %{"command" => command_args})
    end
  end

  def call_tool(_ctx, _route_ref, "collab.ask_user", _args),
    do:
      {:ok,
       not_available("collab.ask_user", "collaboration prompt delivery is not available yet")}

  def call_tool(_ctx, _route_ref, "collab.fetch_slack_context", _args),
    do: {:ok, not_available("collab.fetch_slack_context", "Slack context is not available yet")}

  def call_tool(_ctx, _route_ref, tool, _args), do: {:error, {:unknown_tool, tool}}

  defp read_document_resource(ctx, route_ref, document_id, kind, uri)
       when kind in @document_resource_kinds do
    with :ok <- authorize_route_ref(route_ref, document_id),
         :ok <- Gateway.authorize_document(ctx, document_id),
         {:ok, state} <- Runtime.load(ctx, document_id),
         {:ok, body} <- document_resource_body(ctx, state, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp read_document_resource(_ctx, _route_ref, _document_id, _kind, _uri),
    do: {:error, :invalid_uri}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "state") do
    {:ok,
     %{
       "document_id" => state.document_id,
       "revision" => state.revision,
       "projection" => state.projection
     }}
  end

  defp document_resource_body(_ctx, %Runtime.State{} = state, "outline"),
    do:
      {:ok,
       %{"document_id" => state.document_id, "outline" => get_projection(state, :outline, [])}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "nodes"),
    do: {:ok, %{"document_id" => state.document_id, "nodes" => get_projection(state, :nodes, [])}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "fields"),
    do:
      {:ok,
       %{"document_id" => state.document_id, "fields" => get_projection(state, :fields, %{})}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "marks") do
    marks = state.projection |> Map.get(:marks, %{}) |> map_values()
    {:ok, %{"document_id" => state.document_id, "marks" => marks}}
  end

  defp document_resource_body(ctx, %Runtime.State{} = state, "changes") do
    with {:ok, changes} <- Runtime.sync_since(ctx, state.document_id, 0) do
      {:ok,
       %{"document_id" => state.document_id, "changes" => Enum.map(changes, &render_change/1)}}
    end
  end

  defp document_resource_body(ctx, %Runtime.State{} = state, "revokes") do
    with {:ok, changes} <- Runtime.sync_since(ctx, state.document_id, 0) do
      revokes =
        Enum.filter(
          changes,
          &(&1.status in [:revoked, :partially_revoked] or
              &1.command_kind in ["revoke_change", "resolve_revoke"])
        )

      {:ok,
       %{"document_id" => state.document_id, "revokes" => Enum.map(revokes, &render_change/1)}}
    end
  end

  defp read_source_resource(ctx, route_ref, id, kind, uri) do
    with {:ok, source} <- get_source_document(ctx, route_ref, id),
         {:ok, body} <- source_resource_body(source, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp source_resource_body(%SourceDocument{} = source, "") do
    {:ok,
     %{
       "id" => source.id,
       "document_id" => source.document_id,
       "chat_thread_id" => source.chat_thread_id,
       "mime_type" => source.mime_type,
       "original_filename" => source.original_filename,
       "status" => source.status,
       "regions" => source.regions
     }}
  end

  defp source_resource_body(%SourceDocument{} = source, "regions"),
    do: {:ok, %{"source_document_id" => source.id, "regions" => source.regions || []}}

  defp source_resource_body(%SourceDocument{} = source, "claims") do
    claims = Repo.all(from c in SourceClaim, where: c.source_document_id == ^source.id)

    {:ok,
     %{"source_document_id" => source.id, "claims" => Enum.map(claims, &render_source_claim/1)}}
  rescue
    _ -> {:ok, %{"source_document_id" => source.id, "claims" => []}}
  end

  defp source_resource_body(%SourceDocument{} = source, "links") do
    claims =
      Repo.all(
        from c in SourceClaim,
          where: c.source_document_id == ^source.id and not is_nil(c.linked_document_id)
      )

    {:ok,
     %{"source_document_id" => source.id, "links" => Enum.map(claims, &render_source_claim/1)}}
  rescue
    _ -> {:ok, %{"source_document_id" => source.id, "links" => []}}
  end

  defp source_resource_body(_source, _kind), do: {:error, :invalid_uri}

  defp read_evidence_resource(ctx, route_ref, id, kind, uri) do
    with {:ok, evidence} <- get_evidence(ctx, route_ref, id),
         {:ok, body} <- evidence_resource_body(evidence, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "") do
    {:ok,
     %{
       "id" => evidence.id,
       "document_id" => evidence.document_id,
       "source_document_id" => evidence.source_document_id,
       "provider" => evidence.provider,
       "query" => evidence.query,
       "result" => evidence.result,
       "captured_at" => evidence.captured_at
     }}
  end

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "raw"),
    do: {:ok, %{"evidence_id" => evidence.id, "result" => evidence.result}}

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "citation"),
    do:
      {:ok,
       %{"evidence_id" => evidence.id, "citation" => Map.get(evidence.result || %{}, "citation")}}

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "links") do
    {:ok,
     %{
       "evidence_id" => evidence.id,
       "document_id" => evidence.document_id,
       "source_document_id" => evidence.source_document_id,
       "chat_thread_id" => evidence.chat_thread_id
     }}
  end

  defp evidence_resource_body(_evidence, _kind), do: {:error, :invalid_uri}

  defp document_resources(%Context{} = ctx) do
    ctx
    |> Documents.list_recent_for_scope(limit: 50)
    |> Enum.flat_map(fn doc ->
      Enum.map(@document_resource_kinds, fn kind ->
        %{
          "uri" => "document://#{doc.id}/#{kind}",
          "name" => "#{doc.title || doc.id} #{kind}",
          "description" => "Document #{kind} resource",
          "mimeType" => "application/json"
        }
      end)
    end)
  end

  defp source_document_resources(%Context{user: %{id: owner_id}}) do
    Repo.all(from s in SourceDocument, where: s.owner_id == ^owner_id, limit: 50)
    |> Enum.flat_map(fn source ->
      base = %{
        "uri" => "source_document://#{source.id}",
        "name" => source.original_filename || source.id,
        "description" => "Source document",
        "mimeType" => "application/json"
      }

      children =
        Enum.map(["regions", "claims", "links"], fn kind ->
          %{
            "uri" => "source_document://#{source.id}/#{kind}",
            "name" => "#{source.original_filename || source.id} #{kind}",
            "description" => "Source document #{kind}",
            "mimeType" => "application/json"
          }
        end)

      [base | children]
    end)
  rescue
    _ -> []
  end

  defp source_document_resources(_ctx), do: []

  defp evidence_resources(%Context{user: %{id: owner_id}}) do
    Repo.all(from e in EvidenceSnapshot, where: e.owner_id == ^owner_id, limit: 50)
    |> Enum.flat_map(fn evidence ->
      base = %{
        "uri" => "evidence://#{evidence.id}",
        "name" => "Evidence #{evidence.provider || evidence.id}",
        "description" => "Evidence snapshot",
        "mimeType" => "application/json"
      }

      children =
        Enum.map(["raw", "citation", "links"], fn kind ->
          %{
            "uri" => "evidence://#{evidence.id}/#{kind}",
            "name" => "Evidence #{kind}",
            "description" => "Evidence #{kind}",
            "mimeType" => "application/json"
          }
        end)

      [base | children]
    end)
  rescue
    _ -> []
  end

  defp evidence_resources(_ctx), do: []

  defp get_source_document(%Context{user: %{id: owner_id}}, route_ref, id) do
    case Repo.get(SourceDocument, id) do
      %SourceDocument{owner_id: ^owner_id} = source ->
        with :ok <- authorize_route_ref(route_ref, source.document_id) do
          {:ok, source}
        end

      %SourceDocument{} ->
        {:error, :forbidden}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_source_document(_ctx, _route_ref, _id), do: {:error, :forbidden}

  defp get_evidence(%Context{user: %{id: owner_id}}, route_ref, id) do
    case Repo.get(EvidenceSnapshot, id) do
      %EvidenceSnapshot{owner_id: ^owner_id} = evidence ->
        with :ok <- authorize_route_ref(route_ref, evidence.document_id) do
          {:ok, evidence}
        end

      %EvidenceSnapshot{} ->
        {:error, :forbidden}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_evidence(_ctx, _route_ref, _id), do: {:error, :forbidden}

  defp authorize_route_ref(nil, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: nil}, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: document_id}, document_id), do: :ok
  defp authorize_route_ref(%RouteRef{}, _document_id), do: {:error, :forbidden}

  defp authorize_command(ctx, route_ref, %Command{document_id: document_id})
       when is_binary(document_id) do
    with :ok <- authorize_route_ref(route_ref, document_id),
         do: Gateway.authorize_document(ctx, document_id)
  end

  defp authorize_command(ctx, route_ref, %Command{source_claim_id: claim_id})
       when is_binary(claim_id) do
    with {:ok, claim} <- get_source_claim(ctx, claim_id),
         {:ok, _source} <- get_source_document(ctx, route_ref, claim.source_document_id) do
      :ok
    end
  end

  defp authorize_command(_ctx, _route_ref, %Command{}), do: :ok

  defp get_source_claim(%Context{user: %{id: owner_id}}, claim_id) do
    case Repo.one(
           from c in SourceClaim,
             join: s in SourceDocument,
             on: s.id == c.source_document_id,
             where: c.id == ^claim_id and s.owner_id == ^owner_id
         ) do
      %SourceClaim{} = claim -> {:ok, claim}
      nil -> {:error, :forbidden}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_source_claim(_ctx, _claim_id), do: {:error, :forbidden}

  defp build_command(%Context{} = ctx, nil, raw), do: build_command(ctx, %RouteRef{}, raw)

  defp build_command(%Context{} = ctx, route_ref, raw) when is_map(raw) do
    attrs = %{
      kind: parse_command_kind(Map.get(raw, "kind") || Map.get(raw, :kind)),
      document_id:
        Map.get(raw, "document_id") || Map.get(raw, :document_id) || route_ref.document_id,
      chat_thread_id:
        Map.get(raw, "chat_thread_id") || Map.get(raw, :chat_thread_id) ||
          route_ref.chat_thread_id,
      source_document_id: Map.get(raw, "source_document_id") || Map.get(raw, :source_document_id),
      source_claim_id: Map.get(raw, "source_claim_id") || Map.get(raw, :source_claim_id),
      change_id: Map.get(raw, "change_id") || Map.get(raw, :change_id),
      agent_run_id:
        Map.get(raw, "agent_run_id") || Map.get(raw, :agent_run_id) || route_ref.agent_run_id,
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

  defp parse_command_kind(value), do: parse_enum(value, Ecto.Enum.values(Command, :kind))
  defp parse_actor_type(value), do: parse_enum(value, Ecto.Enum.values(Command, :actor_type))

  defp parse_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: value
  end

  defp parse_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp parse_enum(_value, _allowed), do: nil

  defp fetch_arg(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_params}
    end
  end

  defp normalize_limit(limit, _default) when is_integer(limit) and limit > 0 and limit <= 100,
    do: limit

  defp normalize_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> default
    end
  end

  defp normalize_limit(_, default), do: default

  defp resource_contents(uri, body) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(json_safe(body))
        }
      ]
    }
  end

  defp render_result(%Change{} = change), do: render_change(change)

  defp render_result(%Runtime.State{} = state),
    do: %{
      "document_id" => state.document_id,
      "revision" => state.revision,
      "projection" => state.projection
    }

  defp render_result(other), do: json_safe(other)

  defp render_change(%Change{} = change) do
    %{
      "id" => change.id,
      "document_id" => change.document_id,
      "command_kind" => change.command_kind,
      "base_revision" => change.base_revision,
      "result_revision" => change.result_revision,
      "status" => atom_to_string(change.status),
      "actor_type" => atom_to_string(change.actor_type),
      "actor_id" => change.actor_id,
      "message" => change.message,
      "inserted_at" => change.inserted_at
    }
  end

  defp render_source_claim(%SourceClaim{} = claim) do
    %{
      "id" => claim.id,
      "source_document_id" => claim.source_document_id,
      "region_id" => claim.region_id,
      "proposed_kind" => claim.proposed_kind,
      "proposed_value" => claim.proposed_value,
      "status" => claim.status,
      "linked_document_id" => claim.linked_document_id,
      "linked_node_id" => claim.linked_node_id
    }
  end

  defp not_available(feature, reason),
    do: %{"status" => "not_available", "feature" => feature, "reason" => reason}

  defp parse_custom_uri(uri, prefix) do
    rest = String.replace_prefix(uri, prefix, "")

    case String.split(rest, "/", parts: 2) do
      [id] when id != "" -> {:ok, id, ""}
      [id, path] when id != "" -> {:ok, id, normalize_path(path)}
      _ -> {:error, :invalid_uri}
    end
  end

  defp normalize_path(nil), do: ""
  defp normalize_path("/"), do: ""
  defp normalize_path("/" <> rest), do: rest
  defp normalize_path(path), do: path

  defp get_projection(%Runtime.State{projection: projection}, key, default) do
    Map.get(projection || %{}, key) || Map.get(projection || %{}, Atom.to_string(key)) || default
  end

  defp map_values(map) when is_map(map), do: Map.values(map)
  defp map_values(list) when is_list(list), do: list
  defp map_values(_), do: []

  defp user_id(%Context{user: %{id: id}}), do: id
  defp user_id(_ctx), do: nil

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(value), do: value

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Decimal{} = value), do: Decimal.to_string(value)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(map) when is_map(map),
    do: map |> Map.drop([:__meta__]) |> Map.new(fn {k, v} -> {json_key(k), json_safe(v)} end)

  defp json_safe(value) when is_atom(value), do: atom_to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

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

  defp string_schema, do: %{"type" => "string"}
  defp integer_schema(min, max), do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  defp source_claim_tool(name, description, kind) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" =>
        object_schema(
          %{
            "source_claim_id" => string_schema(),
            "kind" => %{"type" => "string", "const" => kind},
            "payload" => %{"type" => "object"}
          },
          ["source_claim_id"]
        )
    }
  end
end
