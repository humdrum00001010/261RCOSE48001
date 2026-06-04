defmodule Ecrits.Local.OfficeEditSession do
  @moduledoc """
  A supervised, LiveView-owned LibreOfficeKit (LOK) editing session for one open
  office document (docx/pptx/xlsx).

  This is the editor counterpart to the read-only PDF-tile path. It holds the
  live `Libreofficex.Edit` session (the document in LOK memory) and serializes
  every NIF call onto THIS process so a blocking paint/edit never stalls the
  owning LiveView's mailbox. The LiveView drives it with casts carrying its own
  pid; results stream back as messages the LiveView forwards to the
  `OfficeEditor` JS hook via `push_event`:

    * `{:office_edit, {:caret, %{page, x, y, height}}}` — caret moved (px,
      page-local, 1-based page).
    * `{:office_edit, {:tile, %{part, x, y, width, height, png_base64}}}` — a
      painted tile (PNG data URI source). `x/y` are the tile's TWIP origin;
      `width/height` are the canvas pixel size.
    * `{:office_edit, {:error, reason}}` — a guarded failure (never crashes the
      LiveView).

  The session monitors its owner and closes (frees the LOK document) when the
  owner dies, so a navigated-away LiveView leaks nothing. Every public op is
  guarded: a degraded/absent NIF returns `{:error, ...}` rather than crashing.

  Coordinate model (mirrors `Libreofficex.Edit`): LOK is TWIPS internally;
  `hit_test`/caret are page-local PIXELS @96dpi; `paint_tile` takes a canvas
  pixel size + a document TWIP rect.
  """

  use GenServer

  alias Libreofficex.Edit

  require Logger

  @type t :: pid()

  # 1 px @96dpi = 15 twip.
  @twips_per_px 15

  defstruct [:edit, :owner, :owner_ref, :doc_type, :part_count, part: 0]

  # --- Public API -------------------------------------------------------------

  @doc """
  Starts an edit session for `path`, owned by `owner` (default: the caller).

  Returns `{:ok, pid}` or `{:error, reason}`. On a machine without a built LOK
  runtime this returns `{:error, :backend_missing}` (never crashes the caller).
  """
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(path, opts \\ []) when is_binary(path) do
    owner = Keyword.get(opts, :owner, self())

    spec = {__MODULE__, Keyword.merge(opts, path: path, owner: owner)}

    case DynamicSupervisor.start_child(Ecrits.Local.OfficeEditSupervisor, spec) do
      {:ok, pid} ->
        # The child opens the document in its init; if that failed it stops with
        # a reason. A successful start means the document is live.
        case info(pid) do
          {:ok, _info} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:shutdown, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Document metadata: `{:ok, %{doc_type, part_count, page_count}}`."
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  def info(pid), do: safe_call(pid, :info)

  @doc "Posts a click at page-local px on a 1-based page; sends back a `:caret`."
  @spec hit_test(pid(), pos_integer(), number(), number()) :: :ok
  def hit_test(pid, page, x, y), do: GenServer.cast(pid, {:hit_test, page, x, y})

  @doc "Posts a keyboard event (`%{text:}` or `%{key:}`); paints the dirty tiles."
  @spec keyboard(pid(), map()) :: :ok
  def keyboard(pid, event), do: GenServer.cast(pid, {:keyboard, event})

  @doc "Posts IME input (`%{preedit:}`/`%{commit:}`/`%{end: true}`); paints dirty."
  @spec ime(pid(), map()) :: :ok
  def ime(pid, event), do: GenServer.cast(pid, {:ime, event})

  @doc """
  Requests a paint of `part` covering the page-local px viewport rect
  `%{page, x, y, width, height}` (the host's visible window); sends back `:tile`.
  """
  @spec request_tile(pid(), map()) :: :ok
  def request_tile(pid, viewport), do: GenServer.cast(pid, {:request_tile, viewport})

  @doc "Sets the active part (0-based) and repaints; sends back the part dims."
  @spec set_part(pid(), non_neg_integer()) :: :ok
  def set_part(pid, part), do: GenServer.cast(pid, {:set_part, part})

  @doc "Saves the document in place. Returns `:ok` or `{:error, reason}`."
  @spec save(pid()) :: :ok | {:error, term()}
  def save(pid), do: safe_call(pid, :save)

  @doc "Closes the session (frees the LOK document)."
  @spec close(pid()) :: :ok
  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # --- GenServer --------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    owner = Keyword.fetch!(opts, :owner)
    edit_opts = Keyword.take(opts, [:install_dir, :user_profile_url])

    try do
      case Edit.open(path, edit_opts) do
        {:ok, %Edit{} = edit} ->
          ref = Process.monitor(owner)

          part_count =
            case Edit.get_parts(edit) do
              n when is_integer(n) and n > 0 -> n
              _ -> 1
            end

          state = %__MODULE__{
            edit: edit,
            owner: owner,
            owner_ref: ref,
            doc_type: edit.doc_type,
            part_count: part_count
          }

          {:ok, state}

        {:error, reason} ->
          {:stop, {:shutdown, reason}}
      end
    rescue
      e ->
        Logger.warning("[office_edit] open crashed: #{Exception.message(e)}")
        {:stop, {:shutdown, :open_crashed}}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      doc_type: state.doc_type,
      part_count: state.part_count,
      page_count: guarded(fn -> Edit.page_count(state.edit) end, 0)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:save, _from, state) do
    {:reply, guarded(fn -> Edit.save(state.edit) end, {:error, :backend_missing}), state}
  end

  @impl true
  def handle_cast({:hit_test, page, x, y}, state) do
    case guarded(fn -> Edit.hit_test(state.edit, page, x, y) end, {:error, :no_cursor}) do
      {:ok, caret} -> notify(state, {:caret, normalize_caret(caret)})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:keyboard, event}, state) do
    apply_edit(state, fn -> Edit.keyboard(state.edit, event) end)
    {:noreply, state}
  end

  def handle_cast({:ime, event}, state) do
    apply_edit(state, fn -> Edit.ext_text_input(state.edit, event) end)
    {:noreply, state}
  end

  def handle_cast({:request_tile, viewport}, state) do
    paint_viewport(state, viewport)
    {:noreply, state}
  end

  def handle_cast({:set_part, part}, state) do
    guarded(fn -> Edit.set_part(state.edit, part) end, :ok)
    state = %{state | part: part}
    # Repaint the whole (now active) part at a default canvas.
    paint_full_part(state, part)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    guarded(fn -> Edit.close(state.edit) end, :ok)
    :ok
  end

  # --- internals --------------------------------------------------------------

  # Run an edit op (keyboard/ime), then: push the new caret, and repaint exactly
  # the LOK-invalidated dirty region (twips) so the host updates in real time.
  defp apply_edit(state, fun) do
    case guarded(fun, {:error, :backend_missing}) do
      {:ok, reply} ->
        case Map.get(reply, :cursor) do
          %{} = caret -> notify(state, {:caret, normalize_caret(caret)})
          _ -> :ok
        end

        repaint_invalidated(state, Map.get(reply, :invalidated, []))

      _ ->
        :ok
    end
  end

  # Repaint each LOK dirty rect (document twips). A whole-doc invalidation
  # ({_,_,-1,-1}) repaints the active part in full.
  defp repaint_invalidated(state, rects) when is_list(rects) do
    part = active_part(state)

    Enum.each(rects, fn
      {_x, _y, w, h} when w <= 0 or h <= 0 ->
        paint_full_part(state, part)

      {x, y, w, h} ->
        paint_rect(state, part, x, y, w, h)

      _ ->
        :ok
    end)
  end

  defp repaint_invalidated(_state, _), do: :ok

  # Paint the host's visible viewport (page-local px rect on a 1-based page)
  # converted to document twips for the active part.
  defp paint_viewport(state, viewport) when is_map(viewport) do
    part = active_part(state)
    page = vp(viewport, :page, 1)

    page_origin = page_origin_twips(state, page)
    x_px = vp(viewport, :x, 0)
    y_px = vp(viewport, :y, 0)
    w_px = vp(viewport, :width, 0)
    h_px = vp(viewport, :height, 0)

    tile_x = page_origin.x + px_to_twip(x_px)
    tile_y = page_origin.y + px_to_twip(y_px)
    tile_w = px_to_twip(max(w_px, 1))
    tile_h = px_to_twip(max(h_px, 1))

    paint_rect(state, part, tile_x, tile_y, tile_w, tile_h)
  end

  defp paint_viewport(_state, _), do: :ok

  # Paint the entire active part into a single canvas sized to the part's twip
  # extent (capped so we never allocate a huge buffer). Used for the initial
  # render and whole-doc invalidations.
  defp paint_full_part(state, part) do
    case guarded(fn -> Edit.doc_size(state.edit) end, {:error, :backend_missing}) do
      {:ok, %{width: tw, height: th}} when is_integer(tw) and is_integer(th) and tw > 0 and th > 0 ->
        paint_rect(state, part, 0, 0, tw, th)

      _ ->
        :ok
    end
  end

  # Paint a document twip rect of `part` and push the resulting PNG tile. The
  # canvas pixel size is the rect's twip size at 96dpi, *2 for crispness, capped.
  defp paint_rect(state, part, tile_x, tile_y, tile_w, tile_h) do
    scale = 2.0
    canvas_w = twip_to_px(tile_w) |> mul_round(scale) |> clamp(1, 4000)
    canvas_h = twip_to_px(tile_h) |> mul_round(scale) |> clamp(1, 4000)

    geo = %{
      canvas_w: canvas_w,
      canvas_h: canvas_h,
      tile_x: tile_x,
      tile_y: tile_y,
      tile_w: tile_w,
      tile_h: tile_h
    }

    case guarded(fn -> Edit.paint_tile(state.edit, part, geo) end, {:error, :backend_missing}) do
      {:ok, %{png: png} = tile} when is_binary(png) and byte_size(png) > 0 ->
        page_origin = nearest_page_for_twip_y(state, tile_y)

        notify(state, {
          :tile,
          %{
            part: part,
            page: page_origin.page,
            # px position WITHIN the page box (for the host to place the tile).
            x: twip_to_px(tile_x - page_origin.x),
            y: twip_to_px(tile_y - page_origin.y),
            tile_w: twip_to_px(tile_w),
            tile_h: twip_to_px(tile_h),
            width: Map.get(tile, :width, canvas_w),
            height: Map.get(tile, :height, canvas_h),
            png_base64: Base.encode64(png)
          }
        })

      _ ->
        :ok
    end
  end

  defp active_part(state), do: state.part

  # The page box (twips) whose y-range contains `doc_y`, or page 1 origin.
  defp nearest_page_for_twip_y(state, doc_y) do
    rects = guarded_page_rects(state)

    found =
      Enum.find_index(rects, fn %{y: y, height: h} -> doc_y >= y and doc_y <= y + h end)

    case found do
      nil ->
        case rects do
          [%{x: x, y: y} | _] -> %{page: 1, x: x, y: y}
          _ -> %{page: 1, x: 0, y: 0}
        end

      idx ->
        %{x: x, y: y} = Enum.at(rects, idx)
        %{page: idx + 1, x: x, y: y}
    end
  end

  defp page_origin_twips(state, page) do
    rects = guarded_page_rects(state)

    case Enum.at(rects, page - 1) do
      %{x: x, y: y} -> %{x: x, y: y}
      _ -> %{x: 0, y: 0}
    end
  end

  defp guarded_page_rects(state) do
    guarded(fn -> Edit.page_rects(state.edit) end, [])
  end

  defp normalize_caret(%{page: page, x: x, y: y, height: h}) do
    %{page: page, x: x, y: y, height: h}
  end

  defp normalize_caret(other), do: other

  defp notify(state, payload) do
    send(state.owner, {:office_edit, payload})
    :ok
  end

  # Run a guarded NIF op; map any raise/absent-NIF to `default`.
  defp guarded(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp safe_call(pid, msg, timeout \\ 10_000) do
    GenServer.call(pid, msg, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp px_to_twip(px) when is_number(px), do: round(px * @twips_per_px)
  defp twip_to_px(twip) when is_number(twip), do: round(twip / @twips_per_px)

  defp mul_round(n, scale), do: round(n * scale)
  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp vp(map, key, default) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_number(n) -> n
      _ -> default
    end
  end
end
