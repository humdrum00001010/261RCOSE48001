defmodule Ecrits.Doc.Projection do
  @moduledoc """
  Deterministic, grep-able UTF-8 **DocLang v0.6 XML** projection of an on-disk
  document.

  This is Layer 3 of `docs/plans/2026-07-26-doclang-engine-migration.md`. It
  renders a WHOLE document — HWP/HWPX/docx/pptx/xlsx — to a single stable byte
  blob that the document VFS serves as `<name>.doclang.xml`, so a human (or the
  agent, whose cwd is the workspace root) can `cat`/`rg` the document's text
  without an MCP round-trip.

  Before 2026-07-26 the mount served a nested `.jsonl` value shaped
  `[section[paragraph[payload_node]]]`, produced by the engine deps' own IR
  modules. Both deps are gone; `Doclang` is the live IR and DocLang XML is the
  mounted format. The `.jsonl` encoder/parser and the two engine-specific diffs
  that fed it are deleted, not deprecated — a mount that can serve two formats
  can serve a stale one.

  ## How the bytes are produced

  The projection goes through the REAL engine, never a bespoke parser. Since
  2026-07-26 that engine lives in the BROWSER:

    1. `engine/4` looks up the LiveView holding the document
       (`Ecrits.Workspace.Session.viewer/2`); no viewer is
       `{:error, {:no_engine, …}}`. This is a LOOKUP, not a routing decision —
       the engine deps were deleted 2026-07-26, `backend_for/1` followed on
       2026-07-28 and the dispatcher around them on the same day, because a
       choice with one destination is not a choice.
    2. That viewer enumerates the FULL document IR (not the 30-paragraph
       `doc.read` window) via `Ecrits.Doc.BrowserBridge.call(lv, :elements, …)`.
       Each IR node is a map carrying at least `"ref"`, `"type"`, and (for
       text-bearing leaves) `"text"`, in document order.
    3. `Doclang.project/2` lowers that IR through the kind's DocLang adapter
       (`Doclang.Adapter.Hwp` | `Doclang.Adapter.Office`) and serializes it as
       DocLang v0.6 XML. Conversion is always `Mode::Preserve`: Lean mode
       discards `FontInfo | CharColor | NamedStyle | SectionSettings |
       FloatingObject | TextBox | TrackChanges | Caption`, and a lossy
       projection makes the diff below UNSOUND — a diff cannot distinguish
       "unchanged and unrepresented" from "deleted".

  ## Cold documents have no engine — and say so

  The mount is a SERVER-side FUSE filesystem; the only surviving engine is
  BROWSER-side. A document with no open viewer therefore has no engine at all,
  and this module **fails explicitly** rather than mounting an empty or partial
  projection:

      {:error, {:no_engine, %{path:, kind:, reason:, hint:}}}

  It deliberately does NOT block waiting for a viewer. `DocFs` answers `getattr`
  and `read` from a single serialized handler process; parking that on a browser
  that may never attach wedges the whole mount, and a shell `cat` has no
  affordance to open one. An honest error reaches the agent as a failing
  `stat`/`read` it can act on, which a silent empty file never could.

  ## Identity and write-back

  Identity is **tree position**, not a synthetic id: DocLang v0.6 has no `id`
  attribute and never emits `Prov`, so the buffer stays ref-less and the engine
  ref is recovered from the LIVE baseline node at the aligned position. A
  changed block text becomes a direct text edit on that node's model; changed
  block properties (including the `<custom>` props Preserve mode carries)
  become backend property writes; a new `<table>` / `<picture>` becomes a native
  insertion; a removed `<picture>` deletes that control. Anything that cannot be
  aligned positionally fails closed with `{:error, :structural_change}` — the
  same contract the JSONL projection had. So editing the mounted
  `.doclang.xml` IS editing the document.

  Determinism is load-bearing: the diff's identity test is literally
  `old == new` on the canonical parsed structures, so the blob carries no
  timestamps, no random ordering and no incidental whitespace — the same
  document content always projects to the same bytes (also the basis of
  `fingerprint/1`).
  """

  import Ecrits.Guards

  alias Ecrits.Doc.BrowserBridge
  alias Ecrits.Doc.DocumentId
  alias Ecrits.Doc.EditLifecycleEvent
  alias Ecrits.AcpAgent.Session, as: AgentSession
  alias Ecrits.Document
  alias Ecrits.Document.{ByteSpool, PreviewSnapshot}
  alias Ecrits.Fuse.{DocMount, OpenDocs}
  alias Ecrits.Workspace.Session
  alias Exfuse.Fs.Real, as: RealFs

  @typedoc "A byte offset range `{start, length}` into the projected blob."
  @type byte_range :: {non_neg_integer(), non_neg_integer()}

  @typedoc "An internal index entry: where a projected record lives + its source ref, if any."
  @type line_index_entry :: {byte_range(), Ecrits.Doc.ref() | nil}

  @typedoc "The internal full projection (only `:bytes` is exposed publicly today)."
  @type projection :: %{
          bytes: binary(),
          line_index: [line_index_entry()],
          fingerprint: term()
        }

  @supported_exts ~w(.hwp .hwpx .docx .pptx .xlsx)
  # The mounted projection's suffix. `.doclang.xml` and not a bare `.xml`: it
  # names the dialect for the agent reading it, still ends in `.xml` for every
  # editor/highlighter that keys off the extension, and cannot be confused with
  # a plain XML file a workspace happens to contain.
  @projected_suffix ".doclang.xml"
  @browser_transaction_supervisor Ecrits.Doc.BrowserTransactionSupervisor
  # A full-document enumeration is a bulk read: the HWP arm walks every section's
  # paragraph outline and the office arm parses the whole IR JSON. Both are far
  # slower than the 8s single-verb default on a real Korean document.
  @browser_elements_timeout 60_000

  @doc "The file extensions this projection can render (downcased, with the dot)."
  @spec supported_exts() :: [String.t()]
  def supported_exts, do: @supported_exts

  @doc """
  Whether `path` names a document this projection supports, by extension
  (case-insensitive).
  """
  @spec supported?(String.t()) :: boolean()
  def supported?(path) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> Kernel.in(@supported_exts)
  end

  def supported?(_path), do: false

  @doc """
  The pool `document_id` for the document at `abs_path`.

  This is the SAME id `Ecrits.Workspace.Session`'s viewer registry is keyed by —
  `Ecrits.Doc.DocumentId.for_path/2` over the extension's kind, which is how
  every `attach_viewer/3` caller derives it. Exposed so a caller holding only a
  path (the doc VFS listing, which must ask "does this file have a viewer?")
  reuses that derivation instead of minting a second id scheme.

  `{:error, {:unsupported, ext}}` for anything `supported?/1` rejects.
  """
  @spec document_id(String.t()) :: {:ok, DocumentId.t()} | {:error, term()}
  def document_id(abs_path) when is_binary(abs_path) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, kind} <- kind_for(abs_path) do
      {:ok, DocumentId.for_path(abs_path, kind)}
    end
  end

  @doc """
  The suffix appended to a source name to get its mounted projection name.

      iex> Ecrits.Doc.Projection.projected_suffix()
      ".doclang.xml"
  """
  @spec projected_suffix() :: String.t()
  def projected_suffix, do: @projected_suffix

  @doc """
  The projected filename for a source `name`: append `projected_suffix/0`.

      iex> Ecrits.Doc.Projection.projected_name("report.hwp")
      "report.hwp.doclang.xml"
  """
  @spec projected_name(String.t()) :: String.t()
  def projected_name(name) when is_binary(name), do: name <> @projected_suffix

  @doc """
  Recover the source basename from a projected name by stripping the trailing
  `projected_suffix/0`. Returns `nil` when `proj_name` does not end in it (so a
  non-projection file in the mount is not mistaken for a source document).

      iex> Ecrits.Doc.Projection.source_basename("report.hwp.doclang.xml")
      "report.hwp"
      iex> Ecrits.Doc.Projection.source_basename("notes.txt")
      nil
  """
  @spec source_basename(String.t()) :: String.t() | nil
  def source_basename(proj_name) when is_binary(proj_name) do
    if String.ends_with?(proj_name, @projected_suffix) do
      String.replace_suffix(proj_name, @projected_suffix, "")
    else
      nil
    end
  end

  def source_basename(_proj_name), do: nil

  @doc """
  Render the document at absolute `abs_path` to its deterministic UTF-8 blob.

  Looks up the LiveView holding the document (kind inferred from the extension)
  and reads its full IR from it. Returns `{:ok, bytes}` on success, or
  `{:error, reason}` for an unsupported extension, a document with no live
  engine (`{:no_engine, info}` — see the moduledoc), or an engine error. Never
  raises.

  `opts`:

    * `:root` — the workspace root that owns the document. Supplied by every
      caller that has one (`DocFs`, `Doc.Tools`); without it the root is
      recovered from the running workspace sessions, which is one extra lookup
      and one more way to be wrong, so pass it.
  """
  @spec project_file(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def project_file(abs_path, opts \\ [])

  def project_file(abs_path, opts) when is_binary(abs_path) and is_list(opts) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, projection} <- build_projection(abs_path, opts) do
      {:ok, projection.bytes}
    end
  rescue
    error -> {:error, {:projection_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def project_file(_abs_path, _opts), do: {:error, :invalid_path}

  @doc """
  A stable fingerprint of the document's projected content: it changes iff the
  projection bytes change.

  Returns `{:ok, term}` (a `:erlang.phash2/1` of the bytes — the cheapest
  correct option, since the browser engine exposes no independent IR fingerprint)
  or `{:error, reason}` when the document cannot be projected. Used for the VFS
  `getattr` size/mtime signal.
  """
  @spec fingerprint(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def fingerprint(abs_path, opts \\ [])

  def fingerprint(abs_path, opts) when is_binary(abs_path) and is_list(opts) do
    case project_file(abs_path, opts) do
      {:ok, bytes} -> {:ok, :erlang.phash2(bytes)}
      {:error, _reason} = error -> error
    end
  end

  def fingerprint(_abs_path, _opts), do: {:error, :invalid_path}

  @doc """
  A small post-edit excerpt of the document at `abs_path`, for surfacing WHERE
  an edit landed (the chat-rail doc-edit card).

  Projects the document (reflecting the live, possibly-unsaved viewer model), drops the
  structural `#! <type>` annotation lines, and returns a `:context`-line window
  around the first text line that contains `:marker` (the edit's inserted/
  replaced text). Returns `{:ok, %{found?: boolean, rows: [%{text, hit?}]}}` —
  `hit?` flags the edited line. `found?` is false (rows empty) when the marker is
  absent (e.g. a pure deletion) or the doc cannot be projected. Never raises.
  """
  # [deprecated] dead code — no callers in lib or test (dead-code audit 2026-07-13: xref + repo grep + runtime trace)
  @spec edit_excerpt(String.t(), keyword()) ::
          {:ok, %{found?: boolean(), rows: [%{text: String.t(), hit?: boolean()}]}}
  def edit_excerpt(abs_path, opts \\ []) do
    marker = opts |> Keyword.get(:marker) |> normalize_marker()
    context = Keyword.get(opts, :context, 3)

    with marker when is_binary(marker) <- marker,
         {:ok, bytes} <- project_file(abs_path) do
      # The projection is DocLang XML; show the blocks' TEXT (not raw markup),
      # drop empty/structural blocks, and collapse adjacent duplicates.
      texts =
        case Doclang.parse_blocks(bytes) do
          {:ok, blocks} -> blocks
          _ -> []
        end
        |> Enum.flat_map(&[&1 | Doclang.child_blocks(&1)])
        |> Enum.map(&Doclang.text/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.dedup()

      case Enum.find_index(texts, &String.contains?(&1, marker)) do
        nil ->
          {:ok, %{found?: false, rows: []}}

        i ->
          lo = max(i - context, 0)
          hi = min(i + context, length(texts) - 1)
          rows = for n <- lo..hi, do: %{text: Enum.at(texts, n), hit?: n == i}
          {:ok, %{found?: true, rows: rows}}
      end
    else
      _ -> {:ok, %{found?: false, rows: []}}
    end
  rescue
    _ -> {:ok, %{found?: false, rows: []}}
  end

  # The inserted text may be multi-paragraph (insert_text with "\n" splits into
  # paragraphs, each its own projected line), so match on the FIRST non-empty
  # line of the marker.
  defp normalize_marker(m) when is_binary(m) do
    m |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))
  end

  defp normalize_marker(_), do: nil

  # --- internal projection build -------------------------------------------

  # Resolve the document's live engine and run the full-IR render against it.
  # Factored out of `project_file/2` so `prepare_write_back/3` reuses the same
  # engine path and recovers the `line_index` (which `project_file/2` drops).
  @spec build_projection(String.t(), keyword()) :: {:ok, projection()} | {:error, term()}
  defp build_projection(abs_path, opts) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, kind} <- kind_for(abs_path),
         {:ok, nodes, _document_id} <- ir_nodes(abs_path, kind, opts) do
      {:ok, render_elements(editable_nodes(nodes, kind), kind)}
    end
  end

  # A projection is only useful if it round-trips: `Doclang.changes/3` aligns the
  # PARSED candidate against the adapter's bindings, so if rendering the nodes and
  # parsing that XML back disagree on the block tree, the document fails its own
  # no-op diff and EVERY edit is rejected as `:structural_change` — including
  # edits nowhere near the offending element.
  #
  # This bites on real HWP tables: OTSL writes `<ecel/>` for both an empty cell
  # and a hole in the geometry, and the span-cover tokens re-derive shape on read,
  # so some spanned tables do not survive the trip. Rather than serve a projection
  # that cannot be written back, drop the element types that break it and keep the
  # body paragraphs, which do round-trip. Narrower, never silently unwritable.
  defp editable_nodes(nodes, kind) do
    if round_trips?(nodes, kind) do
      nodes
    else
      reduced = Enum.reject(nodes, &(Map.get(&1, "type") in ["table", "cell"]))

      if reduced != nodes and round_trips?(reduced, kind) do
        reduced
      else
        nodes
      end
    end
  end

  defp round_trips?(nodes, kind) do
    # `render_elements/2` returns %{bytes:, fingerprint:, line_index:} — the diff
    # takes the XML itself.
    case render_elements(nodes, kind) do
      %{bytes: xml} when is_binary(xml) -> Doclang.changes(nodes, xml, kind) == []
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Resolve the document `kind` from the file extension. An unsupported
  # extension is a clean `{:error, {:unsupported, ext}}` rather than a guessed
  # default.
  @spec kind_for(String.t()) :: {:ok, Ecrits.Doc.kind()} | {:error, {:unsupported, String.t()}}
  defp kind_for(abs_path) do
    case abs_path |> Path.extname() |> String.downcase() do
      ".hwp" -> {:ok, :hwp}
      ".hwpx" -> {:ok, :hwpx}
      ".docx" -> {:ok, :docx}
      ".pptx" -> {:ok, :pptx}
      ".xlsx" -> {:ok, :xlsx}
      other -> {:error, {:unsupported, other}}
    end
  end

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end

  # --- engine resolution (which viewer holds the document) -------------------

  @doc """
  The document's live IR nodes and the pool document id they were read under —
  the OLD state both `project_file/2` and write-back diff against.

  This is the projection's ONE engine seam. It never opens the document itself:
  a projection is a READ of whatever model is already authoritative, and the
  only surviving engine is the browser's. See `engine/4`.
  """
  @spec ir_nodes(String.t(), Ecrits.Doc.kind(), keyword()) ::
          {:ok, [map()], DocumentId.t()} | {:error, term()}
  def ir_nodes(abs_path, kind, opts \\ []) do
    abs_path = canonical_file_path(abs_path)
    document_id = DocumentId.for_path(abs_path, kind)

    with {:ok, lv} <- engine(abs_path, kind, document_id, opts),
         {:ok, nodes} <- elements(lv, document_id) do
      {:ok, nodes, document_id}
    end
  end

  # The LiveView holding this document's model. A LOOKUP, not a routing
  # decision — there is one possible destination, and reintroducing a dispatcher
  # invites a second. Report `:no_engine` rather than passing a husk error
  # through, so `mount_error` stays truthful.
  @spec engine(String.t(), Ecrits.Doc.kind(), DocumentId.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defp engine(abs_path, kind, document_id, opts) do
    # Prefer the caller's `:root` (every VFS caller has one); otherwise recover
    # the owning workspace from the running sessions.
    root = Keyword.get(opts, :root) || Session.workspace_for(abs_path)
    lv = if is_present(root), do: Session.viewer(root, document_id)

    if is_pid(lv), do: {:ok, lv}, else: {:error, no_engine(abs_path, kind, :no_viewer)}
  end

  # No `arm:` here: it named WHICH of two engines answered, and there is one.
  # `reason:` stays — it names why THIS document has none, which is still a fact
  # the agent can act on.
  defp no_engine(abs_path, kind, reason) do
    {:no_engine,
     %{
       path: abs_path,
       kind: kind,
       reason: reason,
       hint:
         "no live engine for this document: the document engine runs in the BROWSER, " <>
           "so open #{Path.basename(abs_path)} in the workspace (its viewer becomes the " <>
           "authoritative model) and retry. Nothing is projected without one — an empty " <>
           "or partial projection would misrepresent the document."
     }}
  end

  # Full-IR enumeration from the viewer: one `:elements` request over
  # `BrowserBridge`, guarded by `expected_document_id` so a tab switch mid-flight
  # cannot answer with a DIFFERENT document's IR (which write-back would then
  # diff against and lower to edits on the wrong file).
  @spec elements(pid(), DocumentId.t()) :: {:ok, [map()]} | {:error, term()}
  defp elements(lv, document_id) do
    case BrowserBridge.call(lv, :elements, %{}, [
           {:expected_document_id, document_id},
           {:timeout, @browser_elements_timeout}
         ]) do
      {:ok, reply} -> browser_elements(reply)
      {:error, _reason} = error -> error
    end
  end

  # Both browser canvases answer `%{"elements" => [...], "coverage" => ...}`; a
  # bare list is accepted too, so a reply need not carry the envelope.
  # `coverage` is a NAMED, non-silent statement of what the viewer could
  # enumerate — see `coverage/2`.
  defp browser_elements(reply) when is_list(reply), do: {:ok, normalize_nodes(reply)}

  defp browser_elements(%{} = reply) do
    case Map.get(reply, "elements") || Map.get(reply, :elements) do
      nodes when is_list(nodes) -> {:ok, normalize_nodes(nodes)}
      _ -> {:error, {:browser_elements_invalid, reply}}
    end
  end

  defp browser_elements(other), do: {:error, {:browser_elements_invalid, other}}

  defp normalize_nodes(nodes), do: Enum.map(nodes, &normalize_ir_value/1)

  @doc """
  What the viewer can actually enumerate for the document at `abs_path`.

  Returns `{:ok, %{"coverage" => …, "complete" => bool, "note" => …}}` or
  `{:error, reason}`. It exists so a caller can learn, at the moment it decides
  how to edit, that (for example) the
  HWP browser arm projects BODY PARAGRAPHS ONLY — doc-ops-v1 exposes no element
  enumerator, and an HWP control leaves no trace in the paragraph text, so
  nothing reachable over that transport can even count what is missing. (The
  ENGINE can: rhwp_core already exports a per-paragraph control count and a
  typed page control layout, they are simply not routed through the embed RPC.)
  Silence here is what hands an agent a document whose tables it cannot see.
  """
  @spec coverage(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def coverage(abs_path, opts \\ []) when is_binary(abs_path) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, kind} <- kind_for(abs_path),
         document_id = DocumentId.for_path(abs_path, kind),
         {:ok, lv} <- engine(abs_path, kind, document_id, opts),
         {:ok, reported} <- reported_coverage(lv, document_id) do
      {:ok, reconcile_coverage(reported, abs_path, kind, opts)}
    end
  rescue
    error -> {:error, {:coverage_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The viewer reports what it ENUMERATED; `build_projection/2` may then drop
  # element types that do not survive the DocLang round trip (see
  # `editable_nodes/2`).
  # Reporting the viewer's claim unchanged would tell the agent the mount contains
  # tables it cannot find — the exact silence this field exists to prevent.
  defp reconcile_coverage(reported, abs_path, kind, opts) do
    with true <- Map.get(reported, "complete") == true,
         {:ok, nodes, _document_id} <- ir_nodes(abs_path, kind, opts),
         false <- round_trips?(nodes, kind) do
      dropped =
        nodes
        |> Enum.map(&Map.get(&1, "type"))
        |> Enum.filter(&(&1 in ["table", "cell"]))
        |> Enum.uniq()

      Map.merge(reported, %{
        "coverage" => "body_paragraphs",
        "complete" => false,
        "note" =>
          "the engine enumerated #{Enum.join(dropped, "/")} elements, but they do not survive " <>
            "the DocLang round trip for this document, so they were dropped rather than served " <>
            "unwritable: with them present every edit — including one nowhere near a table — is " <>
            "rejected as a structural change. This projection carries body paragraphs only; use " <>
            "doc.find/doc.read for table-cell text."
      })
    else
      _ -> reported
    end
  end

  # No `"arm" => "browser"` in the payload: it was a constant. The agent reads
  # this to learn what IS and ISN'T in the mount, and naming the only possible
  # producer answers a question nobody asked.
  defp reported_coverage(lv, document_id) do
    case BrowserBridge.call(lv, :elements, %{}, [
           {:expected_document_id, document_id},
           {:timeout, @browser_elements_timeout}
         ]) do
      {:ok, %{} = reply} ->
        {:ok,
         %{
           "coverage" => Map.get(reply, "coverage") || "unknown",
           "complete" => Map.get(reply, "complete") == true,
           "note" => Map.get(reply, "note")
         }}

      {:ok, _bare_list} ->
        {:ok, %{"coverage" => "unknown", "complete" => false, "note" => nil}}

      {:error, _reason} = error ->
        error
    end
  end

  # --- IR -> deterministic blob + line index -------------------------------

  # Serialize the FULL document IR as one DocLang v0.6 XML document.
  #
  # `Doclang.project/2` lowers the engine nodes through the arm's adapter
  # (rhwp positional refs | office UNO ref strings) and renders the block tree.
  # The bytes carry NO refs: identity is the node's position in the tree, and
  # write-back recovers the engine ref from the live baseline at the aligned
  # position. The render is deterministic (fixed element-head order, sorted
  # extra attributes, no incidental whitespace) because `changes/3` tests
  # identity with `old == new`.
  @spec render_elements([map()], Ecrits.Doc.kind()) :: projection()
  defp render_elements(nodes, kind) do
    bytes = Doclang.project(nodes, kind)

    %{
      bytes: bytes,
      line_index: [{{0, byte_size(bytes)}, nil}],
      fingerprint: :erlang.phash2(bytes)
    }
  end

  # --- write-back: edited DocLang XML -> direct edits on the live doc ---------

  @doc """
  Apply a direct overwrite of the projected `.doclang.xml` back onto the live
  document at `abs_path` (VFS write-back / Phase 2). `Doclang.changes/3` diffs
  the incoming `new_bytes` against the live baseline blocks and the changed
  fields are applied directly to the mounted server editor: block text changes
  become scoped text edits, table-cell text changes become whole-cell `set_cell`
  writes, a new `<table>` becomes native `insert_table`, a new
  `<picture><src uri=…/></picture>` becomes native picture insertion, a removed
  `<picture>` deletes that control, and changed block/`<custom>` properties
  become native property writes.
  This is not the MCP/browser `doc.edit` -> `document.engine.operation.command` path; that path remains the
  semantic hook for non-VFS editor requests and may only be used later to resync
  an already-open browser viewer.

  `opts`: `:root` (workspace root, for the edit ctx path guard).

  Returns `{:ok, %{applied: n, doc: name}}`, or `{:error, reason}` —
  `{:malformed_xml, detail}` when the buffer is not a complete DocLang document
  (an incomplete write can never parse: the root `</doclang>` is the last token),
  `:structural_change` when the block count/order/identity changed outside the
  supported insert/delete shapes,
  `{:unsupported_edit, :inline_formatting}` when only inline markup changed,
  `{:agent_picture_insert_requires_data_uri, message}` when an agent-owned DocLang
  edit adds a picture whose `src` is not a base64 `data:` URI (the browser engine
  has no filesystem, so bytes must ride inline),
  `:unroutable` when a changed node has no backend ref, or an engine error. Never
  raises. On success, broadcasts `{:vfs_doc_edited, info}` on `doc_vfs:<root>` so
  the chat rail can show where the file edit landed.
  """
  @spec write_back(String.t(), binary(), keyword()) ::
          {:ok, %{applied: non_neg_integer(), doc: String.t()}} | {:error, term()}
  def write_back(abs_path, new_bytes, opts \\ [])
      when is_binary(abs_path) and is_binary(new_bytes) do
    abs_path = canonical_file_path(abs_path)
    opts = Keyword.put(opts, :revision, Document.sha256(new_bytes))

    with {:ok, kind, document_id, changes} <-
           prepare_write_back(abs_path, new_bytes, opts) do
      case changes do
        [] -> {:ok, %{applied: 0, doc: Path.basename(abs_path)}}
        changes -> apply_changes(abs_path, kind, document_id, changes, opts)
      end
    end
  rescue
    error ->
      {:error, {:writeback_raised, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  @doc """
  Run the exact parse, invariant, and IR-diff checks used by `write_back/3`
  without applying or broadcasting any changes.

  Deterministic gates call this before approving a mounted temp candidate so
  an approved buffer cannot later fail the atomic rename on a structural diff.
  """
  @spec validate_write_back(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def validate_write_back(abs_path, new_bytes, opts \\ [])
      when is_binary(abs_path) and is_binary(new_bytes) do
    abs_path = canonical_file_path(abs_path)

    case prepare_write_back(abs_path, new_bytes, opts) do
      {:ok, _kind, _document_id, _changes} -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    error ->
      {:error, {:writeback_validation_raised, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  # The single write-back gate: parse the edited DocLang buffer, align it against
  # the LIVE baseline and lower the difference to engine-neutral change tuples.
  #
  # This is also the mount's completeness check. `Doclang.changes/3` parses the
  # whole buffer before it can diff anything, and `Doclang.Xml` only accepts a
  # document whose root element is closed — so a partially delivered write
  # cannot reach the engine: it fails with `{:malformed_xml, _}` and `DocFs`
  # stages it for a later chunk. There is no lenient/salvage path.
  defp prepare_write_back(abs_path, new_bytes, opts) do
    with {:ok, kind} <- kind_for(abs_path),
         {:ok, raw_nodes, document_id} <- ir_nodes(abs_path, kind, opts) do
      # MUST be the same reduction `build_projection/2` served. The guard can drop
      # element types that fail the round trip, so diffing the agent's buffer
      # against the UNREDUCED baseline would compare a projection that never had
      # tables to nodes that do — and reject every write as a structural change.
      old_nodes = editable_nodes(raw_nodes, kind)

      case Doclang.changes(old_nodes, new_bytes, kind) do
        {:error, reason} ->
          {:error, reason}

        changes when is_list(changes) ->
          with :ok <- validate_agent_picture_changes(changes, opts) do
            {:ok, kind, document_id, changes}
          end
      end
    end
  end

  @doc """
  Validate and diff a complete VFS temp buffer without mutating or saving the
  authoritative document.

  `DocFs` calls this as soon as an out-of-order FSKit write sequence first forms
  a valid projection. It publishes a transient `:candidate` revision for the
  owning rail to render without persisting it. The later atomic rename performs
  `write_back/3` synchronously with the same `:edit_id` and revision, publishing
  `:committed`; a failed rename publishes the exact `:rejected` identity.
  """
  @spec preview_write_back(String.t(), binary(), keyword()) ::
          {:ok, %{previewed: non_neg_integer(), tokens: non_neg_integer(), doc: String.t()}}
          | {:error, term()}
  def preview_write_back(abs_path, new_bytes, opts \\ [])
      when is_binary(abs_path) and is_binary(new_bytes) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, _kind, _document_id, changes} <- prepare_write_back(abs_path, new_bytes, opts) do
      case changes do
        [] ->
          {:ok, %{previewed: 0, tokens: 0, doc: Path.basename(abs_path)}}

        changes ->
          groups = browser_preview_groups(changes)
          applied = List.duplicate(%{}, length(changes))

          preview_opts =
            opts
            |> Keyword.put(:phase, :candidate)
            |> Keyword.put(:revision, Document.sha256(new_bytes))
            |> Keyword.put(:progress_index, 0)
            |> Keyword.put(:progress_total, length(groups))
            |> Keyword.put(:applied_total, 0)
            |> Keyword.put(:preview_only, true)

          broadcast_edit(abs_path, changes, applied, preview_opts)

          {:ok,
           %{previewed: length(changes), tokens: length(groups), doc: Path.basename(abs_path)}}
      end
    end
  rescue
    error -> {:error, {:preview_writeback_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  if Mix.env() == :test do
    # The rhwp arm's legacy positional-JSONL diff. The MOUNT no longer uses it
    # (`Doclang.changes/3` is the seam); it stays exposed so the ported ref
    # grammar keeps its regression coverage until Layer 4 retires it.
    @doc false
    def __compute_ir_changes_for_test__(old_nodes, new_nodes),
      do: Doclang.Adapter.Hwp.changes(old_nodes, new_nodes)

    @doc false
    def __text_highlight_for_test__(op, marker), do: text_highlight(op, marker)

    @doc false
    def __replacement_pair_highlight_for_test__(insert, marker, old_marker),
      do: replacement_pair_highlight(insert, marker, old_marker)

    @doc false
    def __remap_persisted_highlights_for_test__(highlights, changes),
      do: remap_persisted_highlights(highlights, changes)

    @doc false
    def __highlights_for_changes_for_test__(changes, applied),
      do: highlights_for_changes(changes, applied)

    @doc false
    def __browser_preview_groups_for_test__(changes), do: browser_preview_groups(changes)

    @doc false
    def __browser_sets_for_test__(changes), do: browser_sets(changes)

    @doc false
    def __apply_browser_changes_for_test__(lv, abs_path, kind, changes, opts),
      do: apply_browser_changes(lv, abs_path, kind, changes, opts)

    @doc false
    def __broadcast_edit_for_test__(abs_path, changes, applied, opts),
      do: broadcast_edit(abs_path, changes, applied, opts)
  end

  defp normalize_ir_value(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_ir_value(v)} end)
  end

  defp normalize_ir_value(list) when is_list(list), do: Enum.map(list, &normalize_ir_value/1)
  defp normalize_ir_value(other), do: other

  # The rhwp insert_table op-builder (and its `first_table_marker`) lives in
  # `Doclang.Adapter.Hwp`, but `broadcast_edit` still surfaces a table-insert
  # highlight marker for the chat rail — so this tiny marker helper stays here.
  defp first_table_marker(cells) do
    cells
    |> List.flatten()
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  # A write is a file-level modification, but authority belongs to the workspace
  # Session: the viewer holding the document owns the live WASM model. No viewer
  # is no model to write into — the same fact the READ seam reports as
  # `:no_engine`, at the one remaining arm.
  defp apply_changes(abs_path, kind, document_id, changes, opts) do
    # The SAME lookup the read seam uses, so a document can never be readable
    # and unwritable (or the reverse) through two spellings of "who holds it".
    # Its `:no_engine` is remapped: `write_errno/1` maps `:writeback_unroutable`
    # to EINVAL, and a missing viewer is a user-correctable state, not the EIO
    # transport failure an unmapped reason would become.
    case engine(abs_path, kind, document_id, opts) do
      {:ok, lv} ->
        apply_browser_changes(
          lv,
          abs_path,
          kind,
          changes,
          Keyword.put(opts, :expected_document_id, document_id)
        )

      {:error, {:no_engine, %{reason: reason}}} ->
        {:error, {:writeback_unroutable, reason}}
    end
  end

  defp apply_browser_changes(lv, abs_path, kind, changes, opts) do
    run_browser_transaction(fn ->
      do_apply_browser_changes(lv, abs_path, kind, changes, opts)
    end)
  end

  # WorkspaceLive keeps a browser VFS lease under the BrowserBridge caller pid.
  # Keep that pid stable for the whole write transaction, and do not link it to
  # the ACP HandlerRunner that is awaiting the result: if the request owner dies
  # after the durable source replace, this coordinator still owns the lease and
  # finishes vfs_commit (or restores + rolls back) under the same turn fence.
  defp run_browser_transaction(fun) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(@browser_transaction_supervisor, fun)
    Task.await(task, :infinity)
  catch
    :exit, reason -> {:error, {:browser_transaction_coordinator_failed, reason}}
  end

  defp do_apply_browser_changes(lv, abs_path, kind, changes, opts) do
    edit_id =
      Keyword.get_lazy(opts, :edit_id, fn ->
        "vfs-edit-#{System.unique_integer([:positive, :monotonic])}"
      end)

    groups = browser_preview_groups(changes)
    ops = browser_ops(changes)
    sets = browser_sets(changes)
    commit_timeout = Keyword.get(opts, :browser_commit_timeout, 8_000)

    payload =
      %{edit_id: edit_id, ops: ops, sets: sets}
      |> put_browser_transaction_metadata(opts)

    case RealFs.read_native(abs_path) do
      {:ok, source_preimage} ->
        with {:ok, result} <-
               BrowserBridge.call(lv, :vfs_write, payload,
                 timeout: BrowserBridge.vfs_write_timeout()
               ),
             {:ok, bytes} <- ByteSpool.decode(result) do
          case commit_browser_export(
                 lv,
                 abs_path,
                 source_preimage,
                 bytes,
                 edit_id,
                 commit_timeout,
                 kind,
                 opts
               ) do
            {:ok, _committed} ->
              applied = browser_applied_results(changes, result)

              preview_opts =
                opts
                |> Keyword.put(:edit_id, edit_id)
                |> Keyword.put(:phase, :committed)
                |> Keyword.put(:progress_index, length(groups))
                |> Keyword.put(:progress_total, length(groups))
                |> Keyword.put(:applied_total, length(changes))
                |> Keyword.put(:preview_base_url, value(result, "preview_base_url"))
                |> Keyword.put(:browser_authority, true)
                |> Keyword.put(:preview_snapshot_bytes_result, {:ok, bytes})

              broadcast_edit(abs_path, changes, applied, preview_opts)
              {:ok, %{applied: length(changes), doc: Path.basename(abs_path)}}

            {:error, _reason} = error ->
              error
          end
        else
          failure ->
            _ = rollback_browser_write(lv, edit_id, opts)
            browser_writeback_error(kind, failure)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp commit_browser_export(
         lv,
         abs_path,
         source_preimage,
         bytes,
         edit_id,
         commit_timeout,
         kind,
         opts
       ) do
    result =
      with_agent_turn_commit(opts, fn ->
        {:commit_result,
         do_commit_browser_export(
           lv,
           abs_path,
           source_preimage,
           bytes,
           edit_id,
           commit_timeout,
           kind,
           opts
         )}
      end)

    case result do
      {:commit_result, commit_result} ->
        commit_result

      other ->
        _ = rollback_browser_write(lv, edit_id, opts)
        browser_writeback_error(kind, other)
    end
  end

  defp do_commit_browser_export(
         lv,
         abs_path,
         source_preimage,
         bytes,
         edit_id,
         commit_timeout,
         kind,
         opts
       ) do
    case validate_agent_turn(opts) do
      :ok ->
        case RealFs.atomic_write_native(abs_path, bytes) do
          :ok ->
            finish_browser_export_after_source_write(
              lv,
              abs_path,
              source_preimage,
              edit_id,
              commit_timeout,
              kind,
              opts
            )

          failure ->
            _ = rollback_browser_write(lv, edit_id, opts)
            browser_writeback_error(kind, failure)
        end

      failure ->
        _ = rollback_browser_write(lv, edit_id, opts)
        browser_writeback_error(kind, failure)
    end
  end

  defp finish_written_browser_export(
         lv,
         abs_path,
         source_preimage,
         edit_id,
         commit_timeout,
         kind,
         opts
       ) do
    result =
      with :ok <- validate_agent_turn(opts),
           commit_payload <- put_browser_transaction_metadata(%{edit_id: edit_id}, opts),
           {:ok, _committed} = committed <-
             BrowserBridge.call(lv, :vfs_commit, commit_payload, timeout: commit_timeout) do
        committed
      end

    case result do
      {:ok, _committed} = ok ->
        ok

      failure ->
        restore_browser_source_and_rollback(
          lv,
          abs_path,
          source_preimage,
          edit_id,
          kind,
          failure,
          opts
        )
    end
  end

  defp with_agent_turn_commit(opts, fun) do
    case Keyword.get(opts, :turn_commit_fun) do
      turn_commit when is_function(turn_commit, 2) ->
        turn_commit.(agent_turn_identity(opts), fun)

      _default ->
        case Keyword.get(opts, :agent_session) do
          pid when is_pid(pid) ->
            AgentSession.with_turn_commit(pid, agent_turn_identity(opts), fun)

          _legacy_or_server ->
            fun.()
        end
    end
  end

  if Mix.env() == :test do
    defp finish_browser_export_after_source_write(
           lv,
           abs_path,
           source_preimage,
           edit_id,
           commit_timeout,
           kind,
           opts
         ) do
      case browser_transaction_checkpoint(opts, :source_written) do
        :ok ->
          finish_written_browser_export(
            lv,
            abs_path,
            source_preimage,
            edit_id,
            commit_timeout,
            kind,
            opts
          )

        failure ->
          restore_browser_source_and_rollback(
            lv,
            abs_path,
            source_preimage,
            edit_id,
            kind,
            failure,
            opts
          )
      end
    end

    defp browser_transaction_checkpoint(opts, checkpoint) do
      case Keyword.get(opts, :browser_transaction_checkpoint_fun) do
        checkpoint_fun when is_function(checkpoint_fun, 1) ->
          try do
            checkpoint_fun.(checkpoint)
          rescue
            error -> {:error, {:checkpoint_raised, Exception.message(error)}}
          catch
            kind, reason -> {:error, {:checkpoint_failed, kind, reason}}
          end

        _no_checkpoint ->
          :ok
      end
    end
  else
    defp finish_browser_export_after_source_write(
           lv,
           abs_path,
           source_preimage,
           edit_id,
           commit_timeout,
           kind,
           opts
         ) do
      finish_written_browser_export(
        lv,
        abs_path,
        source_preimage,
        edit_id,
        commit_timeout,
        kind,
        opts
      )
    end
  end

  defp validate_agent_turn(opts) do
    case Keyword.get(opts, :agent_session) do
      pid when is_pid(pid) ->
        identity = agent_turn_identity(opts)

        case AgentSession.tool_context(pid) do
          context when is_map(context) ->
            if Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
                 value = Map.get(identity, key)
                 is_present(value) and Map.get(context, key) == value
               end) do
              :ok
            else
              {:error, :turn_invalidated}
            end

          _context ->
            {:error, :turn_invalidated}
        end

      _legacy_or_server ->
        :ok
    end
  catch
    :exit, _reason -> {:error, :turn_invalidated}
  end

  defp agent_turn_identity(opts) do
    Map.new([:agent_id, :instance_id, :turn_id], &{&1, Keyword.get(opts, &1)})
  end

  # An agent MAY insert a picture from the DocLang buffer, but only by carrying the
  # bytes inline as a base64 `data:` URI.
  #
  # The blanket refusal this replaces predated the transport: nothing attached bytes
  # anywhere in the chain, and the engine resolves a bare `src` as a URL — inside the
  # browser WASM sandbox there is no filesystem, so a server-side path could never
  # load. `bin0001.bmp` in the projection is a BinData LABEL inside the document, not
  # a readable address, so echoing one back is meaningless too. http(s) is refused on
  # purpose: an in-op fetch would succeed or fail depending on iframe origin and CSP,
  # making the same op silently mean different things.
  defp validate_agent_picture_changes(changes, opts) do
    if full_agent_turn_identity?(opts) do
      changes
      |> Enum.filter(&match?({:insert_picture, _op, _marker, _props}, &1))
      |> Enum.find(fn {:insert_picture, _op, marker, _props} -> not data_uri_image?(marker) end)
      |> case do
        nil -> :ok
        {:insert_picture, _op, marker, _props} -> {:error, agent_picture_src_error(marker)}
      end
    else
      :ok
    end
  end

  defp data_uri_image?(src) when is_binary(src),
    do: String.starts_with?(src, "data:image/") and String.contains?(src, ";base64,")

  defp data_uri_image?(_src), do: false

  defp agent_picture_src_error(src) do
    {:agent_picture_insert_requires_data_uri,
     "insert_picture needs the image bytes inline as a base64 data URI " <>
       "(<src uri=\"data:image/png;base64,…\"/>); got #{inspect(String.slice(to_string(src), 0, 60))}. " <>
       "A filesystem path cannot be read from the browser engine, an http(s) URL is refused " <>
       "because it would resolve differently per origin/CSP, and a bin<NNNN>.<ext> name is a " <>
       "label inside the document, not an address."}
  end

  defp full_agent_turn_identity?(opts) do
    Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
      case Keyword.get(opts, key) do
        value when is_binary(value) -> String.trim(value) != ""
        _other -> false
      end
    end)
  end

  defp restore_browser_source_and_rollback(
         lv,
         abs_path,
         source_preimage,
         edit_id,
         kind,
         commit_failure,
         opts
       ) do
    restore_result = RealFs.atomic_write_native(abs_path, source_preimage)
    _ = rollback_browser_write(lv, edit_id, opts)

    case restore_result do
      :ok ->
        browser_writeback_error(kind, commit_failure)

      {:error, _reason} = restore_error ->
        {:error, {:browser_source_restore_failed, commit_failure, restore_error}}
    end
  end

  defp rollback_browser_write(lv, edit_id, opts) do
    payload =
      %{edit_id: edit_id}
      |> put_browser_transaction_metadata(opts)

    BrowserBridge.call(lv, :vfs_rollback, payload, timeout: 8_000)
  end

  defp put_browser_transaction_metadata(payload, opts) do
    Enum.reduce([:expected_document_id, :agent_id, :instance_id, :turn_id], payload, fn key,
                                                                                        payload ->
      case Keyword.get(opts, key) do
        value when is_present(value) -> Map.put(payload, key, value)
        _missing -> payload
      end
    end)
  end

  defp browser_writeback_error(_kind, {:error, reason}) when is_binary(reason),
    do: {:error, {:browser_writeback_rejected, reason}}

  defp browser_writeback_error(_kind, {:error, _reason} = error), do: error

  defp browser_writeback_error(kind, other),
    do: {:error, {:browser_writeback_failed, kind, other}}

  defp browser_ops(changes) do
    Enum.flat_map(changes, fn
      {:text, op, _marker} -> [browser_edit_op(op)]
      {:insert_table, op, _marker} -> [browser_edit_op(op)]
      {:insert_picture, op, _marker, props} -> [browser_picture_edit_op(op, props)]
      {:delete_node, op, _marker} -> [browser_edit_op(op)]
      {:set, _ref, _type, _props} -> []
    end)
  end

  defp browser_sets(changes) do
    Enum.flat_map(changes, fn
      {:set, ref, type, props} ->
        props =
          if is_present(type),
            do: Map.put_new(props, "kind", browser_set_kind(type)),
            else: props

        [%{"ref" => ref, "props" => props}]

      _change ->
        []
    end)
  end

  defp browser_set_kind("paragraph"), do: "para"
  defp browser_set_kind(type), do: type

  defp browser_applied_results(changes, result) do
    edit_results =
      result
      |> value("edit")
      |> value("results")
      |> List.wrap()

    set_results =
      result
      |> value("set")
      |> value("results")
      |> List.wrap()

    {applied, _edit_results, _set_results} =
      Enum.reduce(changes, {[], edit_results, set_results}, fn
        {:set, _ref, _type, _props}, {acc, edits, [set | sets]} ->
          {[set | acc], edits, sets}

        {:set, _ref, _type, _props}, {acc, edits, []} ->
          {[%{} | acc], edits, []}

        _change, {acc, [edit | edits], sets} ->
          {[edit | acc], edits, sets}

        _change, {acc, [], sets} ->
          {[%{} | acc], [], sets}
      end)

    Enum.reverse(applied)
  end

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, value_atom(key))
  end

  defp value(_other, _key), do: nil

  defp value_atom("preview_base_url"), do: :preview_base_url
  defp value_atom("edit"), do: :edit
  defp value_atom("set"), do: :set
  defp value_atom("results"), do: :results
  defp value_atom(_key), do: :__missing__

  # A text replacement is represented by a delete_range + insert_text pair.
  # Keep that pair atomic so the rail never flashes an empty document. Every
  # remaining change is already one semantic edit range; expanding inserted text
  # into grapheme-sized groups makes one field look like hundreds of edits and
  # briefly highlights only one character at a time.
  defp logical_change_groups(changes) do
    changes
    |> logical_change_groups([])
    |> Enum.chunk_by(&logical_group_marker/1)
    |> Enum.map(&List.flatten/1)
  end

  # Doclang.Adapter.Hwp deliberately orders authoritative positional writes from the end of
  # the document so earlier refs cannot be shifted by later structural edits.
  # That engine-safe order is not the order a person reads or watches a document
  # being filled. Keep it for the single authoritative batch, but play the
  # non-authoritative browser mirror in document order.
  defp browser_preview_groups(changes) do
    changes
    |> logical_change_groups()
    |> Enum.with_index()
    |> Enum.sort_by(fn {group, index} -> {preview_group_position(group), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp preview_group_position(group) do
    Enum.find_value(group, {1, 0, 0, 0, 0, 0, 0, 0}, fn change ->
      case preview_change_ref(change) do
        %{} = ref ->
          preview_ref_position(ref)

        _other ->
          nil
      end
    end)
  end

  defp preview_ref_position(ref) when is_map(ref) do
    section = Map.get(ref, "section", 0)
    cell = Map.get(ref, "cell")

    paragraph =
      if is_map(cell),
        do: Map.get(cell, "parentParaIndex", Map.get(ref, "paragraph", 0)),
        else: Map.get(ref, "paragraph", 0)

    if is_integer(section) and is_integer(paragraph) do
      {
        0,
        section,
        paragraph,
        if(is_map(cell), do: 1, else: 0),
        if(is_map(cell), do: Map.get(cell, "controlIndex", 0), else: 0),
        if(is_map(cell), do: Map.get(cell, "cellIndex", 0), else: 0),
        if(is_map(cell), do: Map.get(cell, "cellParaIndex", 0), else: 0),
        Map.get(ref, "offset", 0)
      }
    end
  end

  defp preview_ref_position(_ref), do: nil

  defp preview_change_ref({:text, %{"ref" => ref}, _marker}), do: ref
  defp preview_change_ref({:insert_table, %{"ref" => ref}, _marker}), do: ref
  defp preview_change_ref({:insert_picture, %{"ref" => ref}, _marker, _props}), do: ref
  defp preview_change_ref({:delete_node, %{"ref" => ref}, _marker}), do: ref
  defp preview_change_ref({:set, ref, _type, _props}), do: ref
  defp preview_change_ref(_change), do: nil

  defp logical_change_groups([first, second | rest], acc) do
    if text_replacement_pair?(first, second) do
      logical_change_groups(rest, [[first, second] | acc])
    else
      logical_change_groups([second | rest], [[first] | acc])
    end
  end

  defp logical_change_groups([change], acc), do: Enum.reverse([[change] | acc])
  defp logical_change_groups([], acc), do: Enum.reverse(acc)

  defp text_replacement_pair?(
         {:text, %{"op" => "delete_range"} = delete, _old_marker},
         {:text, %{"op" => "insert_text"} = insert, _new_marker}
       ) do
    normalize_ir_value(delete["ref"]) == normalize_ir_value(insert["ref"]) and
      Map.get(delete, "offset", 0) == Map.get(insert, "offset", 0)
  end

  defp text_replacement_pair?(_first, _second), do: false

  defp logical_group_marker(group) do
    Enum.find_value(group, fn
      {:text, _op, marker} when is_binary(marker) -> {:text, marker}
      _other -> nil
    end) || make_ref()
  end

  defp broadcast_edit(abs_path, changes, applied, opts) do
    root = opts[:root]

    if is_binary(root) do
      hit =
        Enum.find_value(changes, fn
          {:text, %{"op" => "insert_text"}, marker} -> marker
          _other -> nil
        end) ||
          Enum.find_value(changes, fn
            {:text, _op, marker} -> marker
            {:insert_table, _op, marker} -> marker
            {:insert_picture, _op, marker, _props} -> marker
            {:delete_node, _op, marker} -> marker
            _other -> nil
          end)

      composition_ops =
        Enum.flat_map(changes, fn
          {:text, op, _marker} -> [op]
          {:insert_table, op, _marker} -> [op]
          {:insert_picture, op, _marker, _props} -> [op]
          {:delete_node, op, _marker} -> [op]
          _other -> []
        end)

      # The live browser cannot read a server-side picture `src`, so its playback
      # op carries transient inline bytes. The composition copy above remains
      # byte-free and is the only copy persisted in the ACP session descriptor.
      ops =
        Enum.map(composition_ops, fn
          %{"op" => "insert_picture"} = op -> browser_edit_op(op)
          op -> op
        end)

      highlights = highlights_for_changes(changes, applied)

      sets =
        changes
        |> Enum.zip(applied)
        |> Enum.flat_map(fn
          {{:set, ref, type, props}, _applied} ->
            props =
              if is_present(type) do
                Map.put_new(props, "kind", type)
              else
                props
              end

            [%{"ref" => ref, "props" => props}]

          {{:insert_picture, op, _marker, props}, applied} ->
            cond do
              props == %{} ->
                []

              not is_map(props) ->
                []

              true ->
                case inserted_control_ref(op, applied) do
                  {:ok, ref} ->
                    [%{"ref" => ref, "props" => Map.put_new(props, "kind", "picture")}]

                  {:error, _reason} ->
                    []
                end
            end

          {_other, _applied} ->
            []
        end)

      info =
        %{
          phase:
            opts[:phase] || if(opts[:preview_only] == true, do: :candidate, else: :committed),
          turn_id: opts[:turn_id],
          edit_id: opts[:edit_id],
          document_id: preview_document_id(root, abs_path),
          path: abs_path,
          doc: Path.basename(abs_path),
          revision: opts[:revision],
          ops: ops,
          sets: sets,
          highlights: highlights,
          preview_snapshot: nil,
          preview_snapshot_error: nil,
          agent_id: opts[:agent_id],
          instance_id: opts[:instance_id],
          applied: opts[:applied_total] || length(changes),
          delta_applied: length(changes),
          progress_index: opts[:progress_index],
          progress_total: opts[:progress_total],
          marker: hit,
          composition_ops: composition_ops
        }
        |> maybe_put_info(:preview_steps, opts[:preview_steps])
        |> maybe_put_info(:preview_base_url, opts[:preview_base_url])
        |> maybe_put_info(:browser_authority, opts[:browser_authority])
        |> maybe_put_info(:preview_only, opts[:preview_only])
        |> maybe_put_info(:preview_continuation, opts[:preview_continuation])
        |> maybe_put_vfs_agent_id(Keyword.get(opts, :agent_id))
        |> maybe_put_vfs_instance_id(Keyword.get(opts, :instance_id))
        |> maybe_put_vfs_turn_id(Keyword.get(opts, :turn_id))

      publish_or_defer_edit(abs_path, root, info, opts)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp publish_or_defer_edit(abs_path, root, info, opts) do
    if final_committed_preview?(opts) do
      publish_edit(root, %{info | phase: :committed})
      token = OpenDocs.begin_preview_publication(root, abs_path, info.edit_id)

      case token do
        {:registry_unavailable, _ref} ->
          publish_edit(
            root,
            info
            |> Map.put(:phase, :snapshot_ready)
            |> Map.put(:preview_snapshot_error, "preview_registry_unavailable")
          )

        token ->
          task = fn -> publish_durable_preview(abs_path, root, info, opts, token) end

          case Task.Supervisor.start_child(Ecrits.Doc.PreviewTaskSupervisor, task) do
            {:ok, _pid} ->
              :ok

            {:error, reason} ->
              publish_current_preview_error(abs_path, root, info, token, reason)
          end
      end
    else
      publish_edit(root, info)
    end
  end

  defp publish_durable_preview(abs_path, root, info, opts, token) do
    {preview_snapshot, preview_snapshot_error} =
      try do
        durable_preview_snapshot(abs_path, root, opts)
      rescue
        error -> {nil, preview_snapshot_error({:exception, Exception.message(error)})}
      catch
        kind, reason -> {nil, preview_snapshot_error({kind, reason})}
      end

    info =
      info
      |> Map.put(:phase, :snapshot_ready)
      |> Map.put(:preview_snapshot, preview_snapshot)
      |> Map.put(:preview_snapshot_error, preview_snapshot_error)
      |> cast_edit_lifecycle_event()

    _ = OpenDocs.publish_preview_if_current(root, abs_path, token, info)
    :ok
  end

  defp publish_current_preview_error(abs_path, root, info, token, reason) do
    info =
      info
      |> Map.put(:phase, :snapshot_ready)
      |> Map.put(:preview_snapshot, nil)
      |> Map.put(:preview_snapshot_error, preview_snapshot_error(reason))
      |> cast_edit_lifecycle_event()

    _ = OpenDocs.publish_preview_if_current(root, abs_path, token, info)
    :ok
  end

  defp preview_document_id(root, abs_path) do
    canonical_root = DocMount.canonical_root(root)
    Document.id_for(canonical_root, Path.relative_to(abs_path, canonical_root))
  end

  defp publish_edit(root, info) do
    info = cast_edit_lifecycle_event(info)

    Phoenix.PubSub.broadcast(
      Ecrits.PubSub,
      "doc_vfs:" <> DocMount.canonical_root(root),
      {:vfs_doc_edited, info}
    )
  end

  defp cast_edit_lifecycle_event(info) do
    info |> EditLifecycleEvent.cast!() |> EditLifecycleEvent.dump()
  end

  defp durable_preview_snapshot(abs_path, root, opts) do
    if final_committed_preview?(opts) do
      canonical_root = DocMount.canonical_root(root)
      relative_path = Path.relative_to(abs_path, canonical_root)
      document_id = Document.id_for(canonical_root, relative_path)
      put_snapshot = Keyword.get(opts, :preview_snapshot_fun, &PreviewSnapshot.put/2)

      with {:ok, bytes} <- preview_snapshot_bytes(abs_path, opts),
           {:ok, snapshot} <- put_snapshot.(document_id, bytes) do
        {snapshot, nil}
      else
        {:error, reason} -> {nil, preview_snapshot_error(reason)}
        other -> {nil, preview_snapshot_error(other)}
      end
    else
      {nil, nil}
    end
  end

  defp preview_snapshot_bytes(abs_path, opts) do
    case Keyword.fetch(opts, :preview_snapshot_bytes_result) do
      {:ok, {:ok, bytes}} when is_binary(bytes) -> {:ok, bytes}
      {:ok, {:error, _reason} = error} -> error
      {:ok, other} -> {:error, {:invalid_snapshot_bytes_result, other}}
      :error -> File.read(abs_path)
    end
  end

  defp preview_snapshot_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp preview_snapshot_error(reason), do: inspect(reason, limit: 8, printable_limit: 160)

  defp final_committed_preview?(opts) do
    if opts[:preview_only] == true do
      false
    else
      case {opts[:progress_index], opts[:progress_total]} do
        {index, total} when is_integer(index) and is_integer(total) and total >= 1 ->
          index >= total

        _other ->
          true
      end
    end
  end

  defp highlights_for_changes(changes, applied) do
    changes
    |> Enum.zip(applied)
    |> highlights_for_change_entries()
    |> remap_persisted_highlights(changes)
    |> sort_preview_highlights()
  end

  defp sort_preview_highlights(highlights) do
    highlights
    |> Enum.with_index()
    |> Enum.sort_by(fn {highlight, index} ->
      ref = Map.get(highlight, "ref") || Map.get(highlight, :ref)
      {preview_ref_position(ref) || {1, 0, 0, 0, 0, 0, 0, 0}, index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # The authoritative write must retain both engine operations for a text
  # replacement, but the committed document only has one visible changed range:
  # the inserted replacement. Dropping the delete highlight here prevents the
  # mirror from painting the same semantic location twice.
  defp highlights_for_change_entries([
         {{:text, _delete, old_marker} = delete_change, _delete_applied} = delete_entry,
         {{:text, insert, marker} = insert_change, _insert_applied} = insert_entry | rest
       ]) do
    if text_replacement_pair?(delete_change, insert_change) do
      [
        replacement_pair_highlight(insert, marker, old_marker)
        | highlights_for_change_entries(rest)
      ]
    else
      highlights_for_change_entry(delete_entry) ++
        highlights_for_change_entries([insert_entry | rest])
    end
  end

  defp highlights_for_change_entries([entry | rest]),
    do: highlights_for_change_entry(entry) ++ highlights_for_change_entries(rest)

  defp highlights_for_change_entries([]), do: []

  defp highlights_for_change_entry(
         {{:text, %{"op" => "insert_paragraph"} = op, marker}, applied}
       ),
       do: inserted_paragraph_highlights(op, marker, applied)

  # A NEW body paragraph from a DocLang buffer insert. `Doclang.insert_change/2`
  # lowers it to `insert_text` with a LEADING "\n" (the browser arm has no
  # insert_paragraph verb; the break splits the paragraph), and the op's ref is the
  # ANCHOR — the end of the PRECEDING paragraph. Falling through to
  # `text_highlight/2` therefore marked the wrong paragraph: the preview landed on
  # the right page with its highlight one paragraph too early, and a zero-width
  # range at a paragraph end yields no rectangle at all.
  #
  # The break is written at the anchor's end, so the text lands in `paragraph + 1`.
  # That is deterministic and needs no engine feedback.
  defp highlights_for_change_entry({{:text, %{"op" => "insert_text"} = op, marker}, _applied}) do
    text = Map.get(op, "text", marker)
    ref = op |> Map.get("ref", %{}) |> normalize_ir_value()

    with true <- is_binary(text),
         "\n" <> inserted <- text,
         section when is_integer(section) <- Map.get(ref, "section"),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph") do
      inserted
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.reject(fn {line, _index} -> line == "" end)
      |> Enum.map(fn {line, index} ->
        %{
          "kind" => "text",
          "op" => "insert_text",
          "ref" => %{
            "section" => section,
            "paragraph" => paragraph + 1 + index,
            "offset" => 0
          },
          "offset" => 0,
          "length" => String.length(line),
          "text" => line
        }
      end)
      |> case do
        [] -> [text_highlight(op, marker)]
        highlights -> highlights
      end
    else
      _ -> [text_highlight(op, marker)]
    end
  end

  defp highlights_for_change_entry({{:text, op, marker}, _applied}),
    do: [text_highlight(op, marker)]

  defp highlights_for_change_entry({{:insert_table, op, _marker}, applied}),
    do: table_insert_highlights(op, applied)

  defp highlights_for_change_entry({{:insert_picture, op, marker, _props}, applied}),
    do: picture_insert_highlights(op, marker, applied)

  defp highlights_for_change_entry({{:delete_node, op, marker}, _applied}) do
    [
      %{
        "kind" => "delete",
        "op" => op["op"],
        "ref" => op["ref"],
        "text" => marker
      }
    ]
  end

  defp highlights_for_change_entry({{:set, ref, type, props}, _applied}) do
    [
      %{
        "kind" => "set",
        "ref" => ref,
        "type" => type,
        "props" => props
      }
    ]
  end

  defp maybe_put_info(info, _key, nil), do: info
  defp maybe_put_info(info, _key, []), do: info
  defp maybe_put_info(info, _key, ""), do: info
  defp maybe_put_info(info, key, value), do: Map.put(info, key, value)

  defp maybe_put_vfs_agent_id(info, agent_id) when is_present(agent_id),
    do: Map.put(info, :agent_id, agent_id)

  defp maybe_put_vfs_agent_id(info, _agent_id), do: info

  defp maybe_put_vfs_instance_id(info, instance_id)
       when is_present(instance_id),
       do: Map.put(info, :instance_id, instance_id)

  defp maybe_put_vfs_instance_id(info, _instance_id), do: info

  defp maybe_put_vfs_turn_id(info, turn_id) when is_present(turn_id),
    do: Map.put(info, :turn_id, turn_id)

  defp maybe_put_vfs_turn_id(info, _turn_id), do: info

  defp text_highlight(op, marker) do
    %{
      "kind" => "text",
      "op" => op["op"],
      "ref" => op["ref"],
      "text" => marker
    }
    |> Map.merge(text_highlight_range(op, marker))
  end

  defp inserted_paragraph_highlights(op, marker, applied) do
    text = Map.get(op, "text", marker)
    section = op |> Map.get("ref", %{}) |> normalize_ir_value() |> Map.get("section", 0)

    with paragraph when is_integer(paragraph) <- applied_paragraph(applied),
         true <- is_integer(section),
         true <- is_binary(text) do
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.reject(fn {line, _index} -> line == "" end)
      |> Enum.map(fn {line, index} ->
        %{
          "kind" => "text",
          "op" => "insert_paragraph",
          "ref" => %{"section" => section, "paragraph" => paragraph + index, "offset" => 0},
          "offset" => 0,
          "length" => String.length(line),
          "text" => line
        }
      end)
      |> case do
        [] -> [text_highlight(op, marker)]
        highlights -> highlights
      end
    else
      _ -> [text_highlight(op, marker)]
    end
  end

  defp applied_paragraph(applied) when is_map(applied) do
    native = Map.get(applied, :native) || Map.get(applied, "native")

    candidate =
      case native do
        [first | _rest] when is_map(first) -> first
        _other -> applied
      end

    Map.get(candidate, "paragraph") || Map.get(candidate, :paragraph) ||
      Map.get(candidate, "paraIdx") || Map.get(candidate, :paraIdx)
  end

  defp applied_paragraph(_applied), do: nil

  defp remap_persisted_highlights(highlights, changes) do
    insertions = positional_insertions(changes)

    paragraph_insertions =
      Enum.filter(insertions, &match?({_section, _paragraph, _mode, _count, :paragraph}, &1))

    Enum.map(highlights, fn
      %{"op" => op} = highlight when op in ["insert_picture", "insert_paragraph"] ->
        highlight

      %{"op" => "insert_table", "ref" => %{} = ref} = highlight ->
        Map.put(highlight, "ref", remap_persisted_ref(ref, paragraph_insertions))

      %{"ref" => %{} = ref} = highlight ->
        Map.put(highlight, "ref", remap_persisted_ref(ref, insertions))

      highlight ->
        highlight
    end)
  end

  defp positional_insertions(changes) do
    changes
    |> Enum.flat_map(fn
      {:insert_table, %{"ref" => %{} = ref}, _marker} ->
        # Native HWP table creation retains the insertion anchor and emits a
        # table paragraph followed by two structural empty paragraphs. Later
        # flattened paragraph refs therefore move by three slots, not one.
        positional_insertion(ref, :after, 3, :table)

      {:text, %{"op" => "insert_paragraph", "ref" => %{} = ref} = op, _marker} ->
        count =
          case Map.get(op, "text") do
            text when is_binary(text) -> text |> String.split("\n", trim: false) |> length()
            _text -> 1
          end

        positional_insertion(ref, :after, max(count, 1), :paragraph)

      {:insert_picture, %{"ref" => %{} = ref}, _marker, _props} ->
        positional_insertion(ref, :at, 1, :picture)

      _change ->
        []
    end)
    |> Enum.sort_by(fn {section, paragraph, _mode, _count, _kind} -> {section, paragraph} end)
  end

  defp positional_insertion(ref, mode, count, kind) do
    section = Map.get(ref, "section")
    paragraph = Map.get(ref, "paragraph")

    if is_integer(section) and is_integer(paragraph),
      do: [{section, paragraph, mode, count, kind}],
      else: []
  end

  defp remap_persisted_ref(ref, insertions) do
    section = Map.get(ref, "section")
    paragraph = Map.get(ref, "paragraph")

    if is_integer(section) and is_integer(paragraph) do
      delta = positional_paragraph_delta(insertions, section, paragraph)

      ref
      |> Map.put("paragraph", paragraph + delta)
      |> remap_cell_parent_paragraph(insertions, section)
    else
      ref
    end
  end

  defp positional_paragraph_delta(insertions, section, paragraph) do
    remapped_paragraph =
      Enum.reduce(insertions, paragraph, fn
        {^section, anchor, :after, count, _kind}, current when current > anchor ->
          current + count

        {^section, anchor, :at, count, _kind}, current when current >= anchor ->
          current + count

        _insertion, current ->
          current
      end)

    remapped_paragraph - paragraph
  end

  defp remap_cell_parent_paragraph(%{"cell" => %{} = cell} = ref, insertions, section) do
    case Map.get(cell, "parentParaIndex") do
      paragraph when is_integer(paragraph) ->
        delta = positional_paragraph_delta(insertions, section, paragraph)
        put_in(ref, ["cell", "parentParaIndex"], paragraph + delta)

      _paragraph ->
        ref
    end
  end

  defp remap_cell_parent_paragraph(ref, _insertions, _section), do: ref

  # A whole-paragraph rewrite arrives as a delete_range + insert_text pair
  # whose insert carries the ENTIRE new text — highlighting it verbatim boxed
  # the whole paragraph (user: "highlight only changes not a whole para").
  # The dropped delete's marker is the OLD text, so narrow the highlight to
  # the range that actually differs.
  defp replacement_pair_highlight(insert, marker, old_marker) do
    highlight = text_highlight(insert, marker)
    new_text = Map.get(insert, "text", marker)

    if is_binary(old_marker) and is_binary(new_text) and old_marker != new_text do
      {relative_offset, length, text} = replacement_changed_range(old_marker, new_text)

      Map.merge(highlight, %{
        "offset" => ref_offset(insert["ref"]) + relative_offset,
        "length" => length,
        "text" => text
      })
    else
      highlight
    end
  end

  defp text_highlight_range(
         %{"op" => "replace_text", "ref" => ref, "query" => query, "replacement" => replacement},
         _marker
       )
       when is_binary(query) and is_binary(replacement) do
    {relative_offset, length, text} = replacement_changed_range(query, replacement)

    %{
      "offset" => ref_offset(ref) + relative_offset,
      "length" => length,
      "text" => text
    }
  end

  defp text_highlight_range(%{"op" => op, "ref" => ref} = edit, marker)
       when op in ["insert_text", "insert_paragraph", "set_char", "set_cell"] do
    text = Map.get(edit, "text", marker)

    if is_binary(text) do
      %{"offset" => ref_offset(ref), "length" => String.length(text), "text" => text}
    else
      %{}
    end
  end

  defp text_highlight_range(_op, _marker), do: %{}

  defp replacement_changed_range(query, replacement) do
    old = String.graphemes(query)
    new = String.graphemes(replacement)
    prefix = common_prefix_count(old, new)
    suffix = common_suffix_count(Enum.drop(old, prefix), Enum.drop(new, prefix))
    length = max(length(new) - prefix - suffix, 0)
    text = new |> Enum.drop(prefix) |> Enum.take(length) |> Enum.join()

    {prefix, length, text}
  end

  defp common_prefix_count(left, right), do: common_prefix_count(left, right, 0)

  defp common_prefix_count([a | left], [b | right], count) when a == b,
    do: common_prefix_count(left, right, count + 1)

  defp common_prefix_count(_left, _right, count), do: count

  defp common_suffix_count(left, right),
    do: common_prefix_count(Enum.reverse(left), Enum.reverse(right), 0)

  defp ref_offset(%{"offset" => offset}) when is_integer(offset), do: max(offset, 0)
  defp ref_offset(%{offset: offset}) when is_integer(offset), do: max(offset, 0)
  defp ref_offset(_ref), do: 0

  defp table_insert_highlights(op, applied) do
    with {:ok, paragraph, control} <- applied_control_ref(applied),
         section <- table_insert_section(op),
         cells when is_list(cells) <- Map.get(op, "cells") do
      cols = Map.get(op, "cols") || cells |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      cells
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {text, col_index} ->
          cell_index = row_index * cols + col_index

          %{
            "kind" => "text",
            "op" => "insert_table",
            "ref" => %{
              "section" => section,
              "paragraph" => paragraph,
              "offset" => 0,
              "cell" => %{
                "parentParaIndex" => paragraph,
                "controlIndex" => control,
                "cellIndex" => cell_index,
                "cellParaIndex" => 0
              }
            },
            "text" => text
          }
        end)
      end)
    else
      _ ->
        [
          %{
            "kind" => "text",
            "op" => "insert_table",
            "ref" => Map.get(op, "ref"),
            "text" => first_table_marker(Map.get(op, "cells", []))
          }
        ]
    end
  end

  defp picture_insert_highlights(op, marker, applied) do
    case inserted_control_ref(op, applied) do
      {:ok, ref} ->
        [
          %{
            "kind" => "picture",
            "op" => "insert_picture",
            "ref" => ref,
            "text" => marker
          }
        ]

      {:error, _reason} ->
        [
          %{
            "kind" => "picture",
            "op" => "insert_picture",
            "ref" => Map.get(op, "ref"),
            "text" => marker
          }
        ]
    end
  end

  defp inserted_control_ref(op, applied) do
    with {:ok, paragraph, control} <- applied_control_ref(applied),
         section <- table_insert_section(op) do
      case inserted_cell_picture_ref(op, section, paragraph, control) do
        {:ok, ref} ->
          {:ok, ref}

        :error ->
          {:ok,
           %{
             "section" => section,
             "paragraph" => paragraph,
             "control" => control,
             "type" => "picture"
           }}
      end
    else
      _ -> {:error, :missing_inserted_control_ref}
    end
  end

  defp applied_control_ref(applied) when is_map(applied) do
    native = Map.get(applied, :native) || Map.get(applied, "native")

    candidate =
      case native do
        [first | _] when is_map(first) -> first
        _ -> applied
      end

    paragraph = Map.get(candidate, "paraIdx") || Map.get(candidate, :paraIdx)
    control = Map.get(candidate, "controlIdx") || Map.get(candidate, :controlIdx)

    if is_integer(paragraph) and is_integer(control),
      do: {:ok, paragraph, control},
      else: {:error, :missing_inserted_control_ref}
  end

  defp applied_control_ref(_applied), do: {:error, :missing_inserted_control_ref}

  defp inserted_cell_picture_ref(op, section, paragraph, control) do
    ref = op |> Map.get("ref") |> normalize_ir_value()
    cell = ref |> Map.get("cell") |> normalize_ir_value()
    cell_path = normalize_cell_path(Map.get(ref, "cellPath") || Map.get(cell || %{}, "cellPath"))

    with true <- Map.get(op, "inline_in_cell") == true,
         %{} <- cell,
         parent_para when is_integer(parent_para) <-
           Map.get(cell, "parentParaIndex") || paragraph,
         table_control when is_integer(table_control) <- Map.get(cell, "controlIndex"),
         cell_index when is_integer(cell_index) <- Map.get(cell, "cellIndex"),
         cell_para when is_integer(cell_para) <- Map.get(cell, "cellParaIndex") do
      cell_path =
        cell_path ||
          [
            %{
              "controlIndex" => table_control,
              "cellIndex" => cell_index,
              "cellParaIndex" => cell_para
            }
          ]

      cell = Map.put(cell, "cellPath", cell_path)

      {:ok,
       %{
         "section" => section,
         "paragraph" => parent_para,
         "offset" => Map.get(ref, "offset", 0),
         "control" => control,
         "type" => "picture",
         "cell" => cell,
         "cellPath" => cell_path
       }}
    else
      _ -> :error
    end
  end

  defp normalize_cell_path([_ | _] = path) do
    path
    |> Enum.map(&normalize_ir_value/1)
    |> Enum.map(fn step ->
      %{
        "controlIndex" => Map.get(step, "controlIndex") || Map.get(step, "control"),
        "cellIndex" => Map.get(step, "cellIndex") || Map.get(step, "cell"),
        "cellParaIndex" => Map.get(step, "cellParaIndex") || Map.get(step, "cell_para")
      }
    end)
    |> Enum.filter(fn step ->
      is_integer(Map.get(step, "controlIndex")) and is_integer(Map.get(step, "cellIndex")) and
        is_integer(Map.get(step, "cellParaIndex"))
    end)
    |> case do
      [] -> nil
      path -> path
    end
  end

  defp normalize_cell_path(_other), do: nil

  defp browser_edit_op(%{"op" => "insert_picture"} = op) do
    atom_op =
      %{
        op: Map.get(op, "op"),
        ref: Map.get(op, "ref"),
        src: Map.get(op, "src"),
        bins: Map.get(op, "bins"),
        image_base64: Map.get(op, "image_base64"),
        extension: Map.get(op, "extension"),
        width: Map.get(op, "width"),
        height: Map.get(op, "height"),
        natural_width_px: Map.get(op, "natural_width_px"),
        natural_height_px: Map.get(op, "natural_height_px"),
        description: Map.get(op, "description"),
        inline_in_cell: Map.get(op, "inline_in_cell")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    # `Doc.Rhwp.Image.for_browser/1` attached the image bytes (the browser cannot
    # read the server filesystem); it went with `:ehwp` on 2026-07-26. This clause
    # already fell back to the unmodified op on error, so keep that behaviour
    # rather than crashing — the browser rejects a picture op with no bytes, which
    # is the same outcome the old `{:error, _}` branch produced.
    # See docs/plans/2026-07-26-doclang-engine-migration.md.
    _ = atom_op
    op
  end

  defp browser_edit_op(op), do: op

  # A picture's placement properties require the control ref allocated by the
  # insertion itself. Keep them coupled to the browser insert op so the browser
  # arm can apply both mutations atomically after it discovers that ref.
  defp browser_picture_edit_op(op, props) do
    op = browser_edit_op(op)

    if is_map(props) and map_size(props) > 0 do
      Map.put(op, "post_insert_props", Map.put_new(props, "kind", "picture"))
    else
      op
    end
  end

  defp table_insert_section(op) do
    case normalize_ir_value(Map.get(op, "ref")) do
      %{"section" => section} when is_integer(section) -> section
      _ -> 0
    end
  end
end
