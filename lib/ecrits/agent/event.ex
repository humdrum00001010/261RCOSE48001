defmodule Ecrits.Agent.Event do
  @moduledoc """
  The ONE typed struct on the wire from `Ecrits.AcpAgent.Session` to every chat
  rail (`docs/plans/2026-07-26-doclang-engine-migration.md`, Layer 2).

  Two very different incoming streams normalize into this struct, and
  `Session.emit/2` is the only place that builds it:

    * `{:acp_session_update, _sid, update}` — **narration only**. Text/reasoning
      deltas, tool calls, provider file-operation rows. No ACP adapter ever
      emits a filesystem write, so nothing here is document truth.

    * `{:vfs_doc_edited, info}` — **the actual document patch**. The agent's
      adapter-native Edit/Write landed on the exfuse mount and
      `Ecrits.Doc.Projection` / `Ecrits.Fuse.OpenDocs` broadcast it on
      `doc_vfs:<root>`. Normalized here as `:doc_edited` / `:doc_edit_rejected`
      with the raw lifecycle map preserved in `payload`.

  Field groups:

    * plan core — `:type`, `:turn_id`, `:edit_id`, `:seq`, `:base_revision`,
      `:revision`, `:payload`;
    * wire identity — stamped by `Session.emit/2` so a re-attaching rail can
      order events against a snapshot and reject events from the process
      incarnation it replaced (`:session_id`, `:instance_id`, `:event_seq`,
      `:at`). `:event_seq` is the spelling already on the wire; `:seq` is the
      plan's name for the same cursor and is always set to the same value;
    * narration — the flat per-type fields the rail pattern-matches today.

  Unknown keys handed to `new/1` are folded into `payload` rather than dropped,
  and the struct implements `Access` with a `payload` fallback, so a provider
  field that has not (yet) earned a named slot still reaches the rail.
  """

  @behaviour Access

  @fields [
    # ── plan core ──────────────────────────────────────────────────────
    :type,
    :turn_id,
    :edit_id,
    :seq,
    :base_revision,
    :revision,
    :payload,
    # ── wire identity (stamped by Session.emit/2) ──────────────────────
    :session_id,
    :instance_id,
    :event_seq,
    :at,
    # ── narration: text / reasoning ────────────────────────────────────
    :delta,
    :segment,
    :text,
    :title,
    # ── narration: turn lifecycle ──────────────────────────────────────
    :input,
    :picks,
    :pending,
    :reason,
    # ── narration: tool calls ──────────────────────────────────────────
    :tool_call_id,
    :name,
    :kind,
    :arguments,
    :result,
    # ── narration: provider file operations ────────────────────────────
    :file_operation_id,
    :operation,
    :query,
    :status,
    # ── narration: proposed file-change display state ──────────────────
    :changes,
    :fingerprint,
    # ── document patch (doc_vfs) ───────────────────────────────────────
    :document_id,
    :path,
    :phase
  ]

  defstruct Keyword.put(Enum.map(@fields, &{&1, nil}), :payload, %{})

  @type t :: %__MODULE__{}

  @doc "Every named field on the wire struct."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Normalize any event map into the struct. Named keys become struct fields;
  everything else is merged into `payload` so nothing on the wire is silently
  dropped.
  """
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = event), do: event

  def new(attrs) when is_map(attrs) do
    {named, rest} = Map.split(attrs, @fields)

    payload =
      case Map.get(named, :payload) do
        payload when is_map(payload) -> Map.merge(payload, rest)
        _other -> rest
      end

    struct(__MODULE__, Map.put(named, :payload, payload))
  end

  @doc "Read a named field, falling back to `payload` (atom or string key)."
  @spec field(t() | map(), atom()) :: term()
  def field(%__MODULE__{} = event, key) when is_atom(key) do
    case fetch(event, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  def field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @impl Access
  def fetch(%__MODULE__{payload: payload} = event, key) do
    case Map.fetch(Map.from_struct(event), key) do
      {:ok, nil} -> fetch_payload(payload, key)
      {:ok, value} -> {:ok, value}
      :error -> fetch_payload(payload, key)
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{} = event, key, fun) when is_function(fun, 1) do
    current = field(event, key)

    case fun.(current) do
      {get, update} -> {get, put(event, key, update)}
      :pop -> {current, put(event, key, nil)}
    end
  end

  @impl Access
  def pop(%__MODULE__{} = event, key) do
    {field(event, key), put(event, key, nil)}
  end

  defp put(%__MODULE__{payload: payload} = event, key, value) do
    if key in @fields do
      Map.put(event, key, value)
    else
      %{event | payload: Map.put(payload || %{}, key, value)}
    end
  end

  defp fetch_payload(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        if is_atom(key), do: Map.fetch(payload, Atom.to_string(key)), else: :error
    end
  end

  defp fetch_payload(_payload, _key), do: :error
end
