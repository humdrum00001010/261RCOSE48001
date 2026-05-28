defmodule Contract.Gateway do
  @moduledoc """
  External ingress façade. Implements the SPEC.md §21 surface:

    * `issue_route_ref/2` — mint a signed, time-bounded route_ref token.
    * `verify_route_ref/2` — decode/validate a token back into a
      `%Contract.RouteRef{}`.
    * `mcp_tool/3` — dispatch an inbound MCP `tools/call` request to the
      live `doc.*` handler.

  Slack ingress (`slack_event/1`, `slack_action/1`, `slack_command/1`) is
  intentionally NOT implemented in this build — the `/slack/*` HTTP routes
  remain on `ContractWeb.NotImplementedPlug` (501) until the Slack track
  lands. Calling the Slack functions raises with a clear message.

  ## Auth model

  Per SPEC.md §15 invariant 2: a route_ref carries durable binary_ids
  (`document_id`) only — never pids, never session refs.
  Tokens are minted with `Phoenix.Token.sign/4` against
  `ContractWeb.Endpoint` and the salt `"route_ref"`. Default TTL is 1 hour;
  callers may override via `attrs.ttl` (seconds).

  ## MCP tool dispatch

  `mcp_tool/3` is the single entrypoint that the inbound
  `ContractWeb.MCP.MCPPlug` calls. The gateway exposes only the compact
  agent document surface: `doc.get`, `doc.read`, and `doc.write`.
  """

  alias Contract.Context
  alias Contract.MCP
  alias Contract.RouteRef

  @salt "route_ref"
  @default_ttl 3_600

  @type route_ref_token :: String.t()

  @doc """
  Lists the MCP tool names the inbound gateway exposes. Order is stable so
  tests and external clients can rely on the index.
  """
  @spec tool_names() :: [String.t()]
  def tool_names do
    Enum.map(tools_descriptor(), & &1["name"])
  end

  @doc """
  Returns the canonical MCP `tools/list` payload -- one entry per tool with
  name, description, and JSON-schema `inputSchema`.
  """
  @spec tools_descriptor() :: [map()]
  def tools_descriptor do
    MCP.expanded_tool_descriptors()
  end

  # ----------------------------------------------------------------------------
  # issue_route_ref / verify_route_ref
  # ----------------------------------------------------------------------------

  @doc """
  Mints a signed route_ref token. `attrs` may include:

    * `:document_id` — binary_id (UUID) string or nil
    * `:purpose` — string label (e.g. "slack_thread", "deep_link", "mcp")
    * `:scopes` — list of permission scopes (strings or atoms)
    * `:ttl` — integer seconds; defaults to 3600

  Returns `{:ok, token}`. Returns `{:error, :pid_in_attrs}` if any value in
  the payload is a pid or reference (regression guard for SPEC.md §15.2 —
  route_refs MUST carry only durable binary_ids).
  """
  @spec issue_route_ref(Context.t() | nil, map()) :: {:ok, route_ref_token()} | {:error, term()}
  def issue_route_ref(ctx, attrs) when is_map(attrs) do
    document_id = fetch_id(attrs, :document_id)
    purpose = Map.get(attrs, :purpose) || Map.get(attrs, "purpose") || "generic"
    scopes = Map.get(attrs, :scopes) || Map.get(attrs, "scopes") || []
    ttl = Map.get(attrs, :ttl) || Map.get(attrs, "ttl") || @default_ttl
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id") || user_id(ctx)
    chat_thread_id = Map.get(attrs, :chat_thread_id) || Map.get(attrs, "chat_thread_id")
    base_revision = Map.get(attrs, :base_revision) || Map.get(attrs, "base_revision")
    agent_run_id = Map.get(attrs, :agent_run_id) || Map.get(attrs, "agent_run_id")

    bind_agent_run_id? =
      truthy?(Map.get(attrs, :bind_agent_run_id) || Map.get(attrs, "bind_agent_run_id"))

    cond do
      contains_pid_or_ref?(document_id) or contains_pid_or_ref?(agent_run_id) or
        contains_pid_or_ref?(purpose) or
          contains_pid_or_ref?(scopes) ->
        {:error, :pid_in_attrs}

      not is_integer(ttl) or ttl <= 0 ->
        {:error, :invalid_ttl}

      true ->
        with :ok <- authorize_route_ref_issue(ctx, document_id) do
          # NOTE: by default `agent_run_id`, `issued_at`, and the live wall-clock
          # `expires_at` are intentionally NOT part of the signed payload.
          # The bearer must be deterministic per
          # (user_id, document_id, chat_thread_id) so OpenAI's hosted MCP
          # `tools/list` cache (keyed by bearer) hits across agent turns
          # instead of rebuilding the catalog every first message of the
          # turn (~700ms). A nil-run bearer is not rebound to a later
          # active attempt; doc.* handlers only accept an explicit run id
          # after proving it is the active `Contract.Agent.Document`
          # attempt for the route_ref's (user, doc) scope. See
          # `Contract.RouteRef` for the design write-up.
          #
          # `Phoenix.Token.sign` normally embeds `signed_at` into the
          # token (its key-derivation nonce), which would alone defeat
          # determinism. We pin it to 0 and pin verify's max_age to
          # :infinity. Expiry is enforced by our own day-aligned
          # `expires_at` in the payload so the bearer is stable across
          # turns within the same UTC day.
          now = DateTime.utc_now()
          expires_at = day_aligned_expiry(now, ttl)

          payload =
            %{
              document_id: document_id,
              user_id: user_id,
              chat_thread_id: chat_thread_id,
              base_revision: base_revision,
              purpose: to_string(purpose),
              expires_at: DateTime.to_iso8601(expires_at),
              scopes: Enum.map(scopes, &to_string/1)
            }
            |> maybe_put_bound_agent_run_id(agent_run_id, bind_agent_run_id?)

          token = Phoenix.Token.sign(endpoint(), @salt, payload, signed_at: 0)
          {:ok, token}
        end
    end
  end

  # Round expiry up to a day boundary >= `now + ttl` so two mints of the
  # same (user, doc, thread) within the same UTC day produce byte-equal
  # tokens. For default ttl=3600 the bucket is "end of today UTC"; for
  # ttl > 86400 we keep rounding to the day after `now + ttl`.
  defp day_aligned_expiry(%DateTime{} = now, ttl) when is_integer(ttl) and ttl > 0 do
    target = DateTime.add(now, ttl, :second)

    {:ok, midnight} =
      target
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new(~T[00:00:00], "Etc/UTC")

    midnight
  end

  @doc """
  Verifies a route_ref token. Returns:

    * `{:ok, %Contract.RouteRef{}}` on success.
    * `{:error, :missing}` for `nil` or empty input.
    * `{:error, :expired}` for an expired token.
    * `{:error, :invalid}` for a tampered, malformed, or otherwise invalid
      token.
  """
  @spec verify_route_ref(Context.t() | nil, route_ref_token() | nil) ::
          {:ok, RouteRef.t()} | {:error, :missing | :expired | :invalid}
  def verify_route_ref(_ctx, nil), do: {:error, :missing}
  def verify_route_ref(_ctx, ""), do: {:error, :missing}

  def verify_route_ref(_ctx, token) when is_binary(token) do
    # `max_age: :infinity` because the bearer's `signed_at` is pinned to 0
    # for determinism (see `issue_route_ref/2` notes). Expiration is
    # enforced explicitly via the payload's `expires_at` below.
    case Phoenix.Token.verify(endpoint(), @salt, token, max_age: :infinity) do
      {:ok, %{} = payload} ->
        with {:ok, expires_at} <- parse_iso(Map.get(payload, :expires_at)) do
          if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
            {:error, :expired}
          else
            {:ok,
             %RouteRef{
               document_id: Map.get(payload, :document_id),
               user_id: Map.get(payload, :user_id),
               chat_thread_id: Map.get(payload, :chat_thread_id),
               agent_run_id: Map.get(payload, :agent_run_id),
               agent_run_id_source:
                 if(is_binary(Map.get(payload, :agent_run_id)), do: :route_ref, else: nil),
               base_revision: Map.get(payload, :base_revision),
               purpose: Map.get(payload, :purpose),
               # `issued_at` is no longer in the payload; we backfill
               # with `expires_at - 1 day` so any consumer reading the
               # field still gets a sensible DateTime.
               issued_at: DateTime.add(expires_at, -86_400, :second),
               expires_at: expires_at,
               scopes: Map.get(payload, :scopes, [])
             }}
          end
        else
          _ -> {:error, :invalid}
        end

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  def verify_route_ref(_ctx, _), do: {:error, :invalid}

  defp maybe_put_bound_agent_run_id(payload, agent_run_id, true) when is_binary(agent_run_id) do
    Map.put(payload, :agent_run_id, agent_run_id)
  end

  defp maybe_put_bound_agent_run_id(payload, _agent_run_id, _bind?), do: payload

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  # ----------------------------------------------------------------------------
  # mcp_tool/3
  # ----------------------------------------------------------------------------

  @doc """
  Dispatches an inbound MCP `tools/call` to the matching `doc.*` handler.

  `ctx` is the request-scoped `%Contract.Context{}` (with `:matter` and
  `:perms` already populated from the bearer). `args` is the decoded JSON
  arguments map.

  Returns `{:ok, content_payload}` on success — the caller wraps the payload
  into the MCP `%{content: [%{type: "text", text: rendered}]}` shape.
  """
  @spec mcp_tool(Context.t() | nil, String.t(), map()) :: {:ok, term()} | {:error, term()}
  def mcp_tool(ctx, tool, args) do
    if tool in MCP.expanded_tool_names() do
      route_ref = ctx && Map.get(ctx.perms || %{}, :route_ref)
      MCP.call_tool(ctx, route_ref, tool, args)
    else
      {:error, {:unknown_tool, tool}}
    end
  end

  # ----------------------------------------------------------------------------
  # Slack — explicitly not implemented in this build
  # ----------------------------------------------------------------------------

  @spec slack_event(map()) :: no_return()
  def slack_event(_payload),
    do: raise("Contract.Gateway.slack_event/1: Slack ingress is out of scope for this build")

  @spec slack_action(map()) :: no_return()
  def slack_action(_payload),
    do: raise("Contract.Gateway.slack_action/1: Slack ingress is out of scope for this build")

  @spec slack_command(map()) :: no_return()
  def slack_command(_payload),
    do: raise("Contract.Gateway.slack_command/1: Slack ingress is out of scope for this build")

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  defp endpoint, do: ContractWeb.Endpoint

  defp user_id(%Context{user: %{id: id}}), do: id
  defp user_id(_ctx), do: nil

  defp fetch_id(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp authorize_route_ref_issue(_ctx, nil), do: :ok

  defp authorize_route_ref_issue(%Context{} = ctx, document_id) when is_binary(document_id) do
    case Contract.Documents.get(ctx, document_id) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_route_ref_issue(_ctx, _document_id), do: {:error, :forbidden}

  defp parse_iso(nil), do: {:error, :missing}

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp parse_iso(_), do: {:error, :invalid}

  defp contains_pid_or_ref?(value)
  defp contains_pid_or_ref?(pid) when is_pid(pid), do: true
  defp contains_pid_or_ref?(ref) when is_reference(ref), do: true
  defp contains_pid_or_ref?(port) when is_port(port), do: true
  defp contains_pid_or_ref?(fun) when is_function(fun), do: true

  defp contains_pid_or_ref?(list) when is_list(list),
    do: Enum.any?(list, &contains_pid_or_ref?/1)

  defp contains_pid_or_ref?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> contains_pid_or_ref?(k) or contains_pid_or_ref?(v) end)
  end

  defp contains_pid_or_ref?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_pid_or_ref?/1)

  defp contains_pid_or_ref?(_), do: false

  # ---- scope enforcement -----------------------------------------------------

  @doc false
  @spec authorize_document(Context.t() | nil, binary() | nil) :: :ok | {:error, :forbidden}
  def authorize_document(_ctx, nil), do: {:error, :forbidden}

  def authorize_document(%Context{} = ctx, doc_id) when is_binary(doc_id) do
    case Map.get(ctx.perms || %{}, :route_ref) do
      %RouteRef{document_id: nil} ->
        authorize_visible_document(ctx, doc_id)

      %RouteRef{document_id: ^doc_id} ->
        authorize_pinned_document(ctx, doc_id)

      %RouteRef{} ->
        {:error, :forbidden}

      _ ->
        case ctx.user do
          nil ->
            {:error, :forbidden}

          _ ->
            case Contract.Documents.get(ctx, doc_id) do
              {:ok, _doc} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  def authorize_document(_ctx, _doc_id), do: {:error, :forbidden}

  defp authorize_visible_document(%Context{} = ctx, doc_id) do
    case Contract.Documents.get(ctx, doc_id) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_pinned_document(%Context{} = ctx, doc_id),
    do: authorize_visible_document(ctx, doc_id)
end
