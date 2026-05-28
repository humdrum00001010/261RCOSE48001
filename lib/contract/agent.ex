defmodule Contract.Agent do
  @moduledoc """
  Semantic interpreter. Agent resolves targets; backend validates returned
  IDs.

  This module owns prompt assembly and final-text decoding. Runtime ownership
  lives at `Contract.Agent.Document`.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` for the verified
  OpenAI Responses + Korean Law MCP shapes.
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Types, as: T

  @grill_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다. 한국어 존댓말로 사용자와 자연스럽게 대화합니다.

  기본 원칙:
    * 사용자에게 친절히 답하세요. 모든 메시지가 편집 요청은 아닙니다.
    * 사용자가 "X를 박아줘", "Y로 바꿔줘", "Z 추가해줘" 같이 **명시적으로 편집을 요청한 경우에만** contract-doc MCP 도구를 호출하세요.
    * 단순 질문 ("어떤 내용인가요?", "이 조항은 무슨 의미?", "안녕"), 의견 요청, 일반 대화는 **도구 호출 없이** 자연스럽게 답하세요.
    * 편집 요청이라도 의도가 모호하면 먼저 한두 문장의 명확화 질문을 하세요. 추측으로 편집하지 마세요.

  편집을 할 때:
    * Use `doc.get` first for aggregate metadata and revision. Use `doc.read(sec, at, size)` for concrete content/navigation windows; `size` defaults to 5. Use `doc.write(sec, para, {base_revision, type, payload:{cmd,payload}})` for edits.
    * 변경 도구에 `base_revision` 을 마지막 본 값으로 고정하세요.
    * 충돌이 나면 `doc.get` 으로 재조회 후 한 번만 재시도하세요.
    * 마치고 나서 무엇을 했는지 한두 문장으로 보고하세요 (예: "0번 단락 끝에 '[X]' 를 박았습니다.").

  법령(민법, 상법 등) 인용은 `korean-law` MCP 의 `verify_citations` 로 먼저 확인.

  중요: 응답은 일반 한국어 대화체 문장입니다. JSON 으로 감싸지 마세요.
  """

  @grill_intro_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다.

  오늘은 사용자가 새 계약 문서를 열었고, 채팅 이력이 비어 있습니다. 당신이 먼저 말을 걸어야 합니다.

  다음 순서로 ONE message에 모두 담아 응답하세요:

  1. 짧은 인사 (한 줄, 격식 있는 한국어).
  2. 문서 본문을 훑고 한 단락(2-3 문장)으로 요약 — 무슨 종류의 계약/문서인지, 주요 당사자나 주제는 무엇인지.
  3. 패킷 맥락을 좁히는 1-3개의 질문을 번호 매겨 제시:
     - 이 패킷이 어떤 일/거래인지
     - 왜 지금 이 계약서가 필요한지
     - 결정/확정해야 할 핵심 슬롯이 무엇인지 (금액·기간·당사자 등)
     질문은 한 문장씩, 한국어 존댓말, 답하기 좋게 구체적으로.

  도구 호출 없이, 순수 한국어 텍스트로 답하세요.

  문서 본문 IR이 비어 있다면 요약 단계를 건너뛰고 곧장 3번의 질문만 던지세요.
  """

  @doc "Returns the system prompt used by `build_context/2`."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @grill_system_prompt

  @doc """
  Returns the Korean grill-intro system prompt used when a document is
  opened cold (empty chat thread). Emitted by `build_context/2` when the
  triggering Command carries `payload["grill_seed"] == true`.
  """
  @spec grill_intro_system_prompt() :: String.t()
  def grill_intro_system_prompt, do: @grill_intro_system_prompt

  # TODO(SPEC.md §18): agent auto-set type_key from marks.
  #
  # When an agent run completes for an untyped document (Document.type_key
  # == nil) and the output contains a label mark
  # (`%{intent: :label, source: :agent, data: %{suggested_type_key: key}}`),
  # this module should automatically emit an `Action(:set_contract_type)`
  # with that key so the user does not have to ratify the obvious. The
  # current fix only stops gating the create flow on type selection; the
  # auto-set is a follow-up that depends on the agent emitting
  # well-formed label marks first.

  @doc """
  Assembles the system prompt, conversation history, MCP tool list, and
  optional `previous_response_id` for one agent run.

  v0.5: Context Reservoir is no longer in spec — the
  `include_context_reservoir/2` helper has been removed.
  """
  @spec build_context(T.ctx(), Command.t()) :: {:ok, map()}
  def build_context(ctx, %Command{} = action) do
    if grill_seed?(action) do
      build_grill_intro_context(action)
    else
      build_regular_context(ctx, action)
    end
  end

  @mcp_tools_addendum """
  도구 — contract-doc MCP:

    * `doc.get` — first call for aggregate metadata only (모든 단락/필드값/표셀본문/outline/index/cursors X). 반환:
      `{ok, revision, d (title), t (type_key), counts}`.
      content/navigation 은 `doc.read(sec, at, size)` 로만 좁게 읽으세요.
    * `doc.read(sec, at, size=5)` — 작은 paragraph window 만 읽습니다.
    * `doc.write(sec, para, {base_revision, type, payload:{cmd,payload}})` — compact mutation tool.
      `type` 은 substrate/family 입니다. Nested `payload.cmd` 는 operation 입니다. Inner `payload.payload` 는 command args 입니다.
      paragraph command: `{type: "paragraph", payload: {cmd: "insert_after_match", payload: {match, text}}}`.
      paragraph command: `{type: "paragraph", payload: {cmd: "insert_before_match", payload: {match, text}}}`.
      paragraph command: `{type: "paragraph", payload: {cmd: "insert_at_offset", payload: {off, text}}}` where `off` is zero-based in the exact `doc.read` item text.
      paragraph command: `{type: "paragraph", payload: {cmd: "insert_paragraph_after", payload: {text}}}`.
      Never put line breaks inside write text. For multi-paragraph drafting, call `doc.write` once per paragraph with newline-free text. Do not replace one template paragraph with an entire contract body.
      For a slot-like date/period edit, first use `doc.read`; write the full exact existing value or paragraph, not only a label prefix.
      Fixed narrow table cells must keep their existing label. In particular, do not relabel `전화번호 :` cells to 담당자/email or put email strings there; put 담당자/email in a wider field only when one exists.

  사용 흐름:

    1. metadata/revision 은 먼저 `doc.get` 으로 확인하세요. 본문은 `doc.read(sec, at, size)` 로 좁게 읽으세요.
    2. 문구 앞/뒤에 정확히 삽입할 때는 `doc.write(sec, para, {base_revision, type: "paragraph", payload: {cmd: "insert_after_match" | "insert_before_match", payload: {match, text}}})` 를 호출하세요. 문단 뒤 새 문단은 `insert_paragraph_after` 와 `{text}` 를 쓰세요.
    3. match 가 빈칸/반복 공백 때문에 애매하면 재시도하지 말고, `doc.read` 의 해당 문단 text 에서 0-based `off` 를 계산해 `insert_at_offset` 을 쓰세요.
    4. 기간/날짜/금액/당사자 같은 슬롯처럼 보이는 값을 고칠 때는 기존 값/문단 전체를 정확히 `match` 로 잡아 교체하세요. 라벨 접두어만 바꾸지 마세요.
    5. 위치를 더 확인해야 하면 broad range 대신 가까운 paragraph window 로 좁게 읽으세요.
    6. 모든 편집을 마친 뒤 사용자에게 한 줄 보고 (예: "제3조 둘째 줄에 문구를 추가했습니다.").
  """

  defp build_regular_context(ctx, %Command{} = action) do
    history = fetch_history(ctx, action)

    # Plain Korean text reply. No JSON envelope coupling — the user-message
    # suffix that forced "Respond in JSON only" is gone now that
    # text.format=json_object isn't set on the request.
    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: action.message || ""}]

    # law_mcp_tool is auto-injected by Contract.IO.OpenAI.build_request, so
    # we only contribute the run-scoped contract-doc tool here. Always
    # attached — the prompt tells the model when not to call it.
    tools =
      case mint_doc_route_ref(ctx, action) do
        {:ok, bearer} ->
          case Contract.IO.OpenAI.contract_doc_mcp_tool(bearer) do
            nil -> []
            tool -> [tool]
          end

        _ ->
          []
      end

    # Task #143/#222/#242/#246 — the full document IR no longer ships in the
    # instructions string, and doc.get is metadata/read-hints only. The schema
    # prompt stays so the agent knows to use doc.read for body content and
    # doc.write for mutations.
    system_prompt =
      [
        @grill_system_prompt,
        @mcp_tools_addendum,
        Contract.Agent.Prompt.IRRenderer.schema_prompt(),
        document_context_note(action.document_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    frame = %{
      system: system_prompt,
      input: input,
      tools: tools,
      previous_response_id: action.payload["previous_response_id"],
      grill_seed?: false
    }

    {:ok, frame}
  end

  # Tiny system-note that pins the current document_id so the agent
  # knows which IR to fetch. Returns nil for non-document contexts so
  # the join doesn't leak an empty section header.
  defp document_context_note(nil), do: nil

  defp document_context_note(doc_id) when is_binary(doc_id) do
    "현재 문서 ID: #{doc_id}\n" <>
      "`doc.get`은 aggregate metadata 전용입니다. " <>
      "본문/위치 탐색은 작은 `doc.read(sec, at, size)` window 로 읽고, 편집은 `doc.write` 로 호출하세요."
  end

  defp mint_doc_route_ref(_ctx, %Command{document_id: nil}), do: {:error, :no_document}

  defp mint_doc_route_ref(
         ctx,
         %Command{
           document_id: doc_id,
           chat_thread_id: thread_id
         } = action
       )
       when is_binary(doc_id) do
    user_id = if ctx, do: get_in(Map.from_struct(ctx), [:user, Access.key!(:id)]), else: nil

    # Task #181 — hosted doc.* calls must carry the current semantic run
    # without asking the model to invent an `agent_run_id` argument. The
    # default route_ref mint path stays deterministic for cacheable callers,
    # but an Agent.Document attempt opts into a run-bound payload so stale
    # attempts cannot be rebound to whatever run becomes active later.
    Contract.Gateway.issue_route_ref(ctx, %{
      user_id: user_id,
      document_id: doc_id,
      chat_thread_id: thread_id,
      agent_run_id: action.agent_run_id,
      bind_agent_run_id: is_binary(action.agent_run_id),
      purpose: "agent_doc_mcp",
      scopes: ["agent_doc"],
      ttl: 24 * 60 * 60
    })
  end

  defp mint_doc_route_ref(_ctx, _action), do: {:error, :missing}

  defp build_grill_intro_context(%Command{} = action) do
    nodes_summary = grill_seed_nodes_summary(action.payload["grill_seed_nodes"])

    user_content =
      case nodes_summary do
        "" -> "DOCUMENT_BODY: (empty)"
        text -> "DOCUMENT_BODY:\n" <> text
      end

    frame = %{
      system: @grill_intro_system_prompt,
      input: [%{role: "user", content: user_content}],
      tools: [],
      previous_response_id: nil,
      grill_seed?: true
    }

    {:ok, frame}
  end

  @doc """
  Renders the projection nodes the LV ships in the grill seed payload
  into a compact plain-text summary. Limits to the first ~25 heading/
  paragraph nodes so the user message stays within a sensible token
  budget for the cold start.
  """
  @spec grill_seed_nodes_summary(term()) :: String.t()
  def grill_seed_nodes_summary(nil), do: ""

  def grill_seed_nodes_summary(nodes) when is_list(nodes) do
    nodes
    |> Enum.take(25)
    |> Enum.map_join("\n", &render_grill_seed_node/1)
  end

  def grill_seed_nodes_summary(_other), do: ""

  defp render_grill_seed_node(%{} = node) do
    kind = node[:kind] || node["kind"]
    content = node[:content] || node["content"] || ""
    "- [#{kind}] #{content}"
  end

  defp render_grill_seed_node(_), do: ""

  @doc "Returns true when `command.payload[\"grill_seed\"]` is truthy."
  @spec grill_seed?(Command.t()) :: boolean()
  def grill_seed?(%Command{payload: payload}) when is_map(payload) do
    Map.get(payload, "grill_seed") == true or Map.get(payload, :grill_seed) == true
  end

  def grill_seed?(_), do: false

  @doc """
  Wraps a plain-text grill-intro response into an `Action(:agent_change)`
  with `mode: "edit"`, empty ops/marks, and the text as `:message`. The
  intro response is rendered as a normal agent chat message and never
  produces document mutations.
  """
  @spec decode_grill_intro(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_grill_intro(text, opts) when is_binary(text) do
    message = String.trim(text)

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{
         "mode" => "edit",
         "ops" => [],
         "marks" => [],
         "message" => message,
         "grill_seed" => true
       },
       message: message
     }}
  end

  def decode_grill_intro(%{} = response, opts) do
    case response_text(response) do
      text when is_binary(text) -> decode_grill_intro(text, opts)
      nil -> {:error, {:decode_failed, {:bad_shape, response}}}
    end
  end

  def decode_grill_intro(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

  @doc """
  Builds an `Action(:agent_change)` from the model's final output.

  Free-form text is the live path. Document writes happen during the stream via
  contract-doc MCP tools; the final assistant text is stored as chat only.
  """
  @spec decode_action(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_action(provider_output, opts \\ [])

  def decode_action(text, opts) when is_binary(text) do
    trimmed = String.trim(text)

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{"mode" => "edit", "ops" => [], "marks" => [], "message" => trimmed},
       message: trimmed
     }}
  end

  def decode_action(%{} = response, opts) do
    case response_text(response) do
      text when is_binary(text) -> decode_action(text, opts)
      nil -> {:error, {:decode_failed, {:bad_shape, response}}}
    end
  end

  def decode_action(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

  # --- internals --------------------------------------------------------

  defp idempotency_key(opts) do
    run_id = Keyword.get(opts, :run_id, "anon")
    turn = Keyword.get(opts, :turn_index, 0)
    "agent:#{run_id}:#{turn}"
  end

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text

  defp response_text(%{"output" => output}) when is_list(output) do
    text =
      output
      |> Enum.flat_map(fn
        %{"content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"text" => t} when is_binary(t) -> [t]
            _ -> []
          end)

        _ ->
          []
      end)
      |> Enum.join("")

    if text == "", do: nil, else: text
  end

  defp response_text(_response), do: nil

  # Task #143/#222 — `fetch_snapshot/2` is gone. The prompt path no longer
  # splices document IR into every request; the agent gets aggregate metadata
  # from doc.get and reads content/navigation through doc.read.
  # This still avoids paying the body-token cost on turns that do not need the
  # document body.

  # Wave-3 owns the chat store; until it lands, return an empty history.
  defp fetch_history(ctx, %Command{} = action), do: ChatThreads.history_for_agent(ctx, action)
end
