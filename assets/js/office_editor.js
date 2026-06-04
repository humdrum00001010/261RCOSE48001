// Server-LOK tile-based office editor hook.
//
// The editable counterpart to the read-only office tile path. Unlike the WASM
// HWP editor (which renders + edits locally), the LIVE document lives in the
// server's LibreOfficeKit (LOK) session: the hook sends input to the server and
// the server pushes back PNG tiles painted by LOK `paintTile` (ms) for exactly
// the LOK-invalidated region. The hook owns one <canvas> + caret-overlay per
// page/slide and draws the pushed tiles into them — mirroring the HWP editor's
// canvas-per-page / caret-overlay / IME-proxy shape.
//
// THE EDIT LOOP:
//   click  -> map to page-local px -> pushEvent("office.edit.hit_test")
//          -> server `office_edit_caret` -> draw caret overlay
//   keydown (non-composing) -> pushEvent("office.edit.key")
//   IME (compositionupdate/end) -> pushEvent("office.edit.ime", {preedit|commit})
//          -> server applies the edit, repaints the LOK dirty tiles, and pushes
//             `office_edit_tile` (PNG) + `office_edit_caret` -> hook redraws.
//   Ctrl/Cmd+S -> pushEvent("office.edit.save")
//
// Korean is sent via the IME path (whole composed strings, e.g. "안"), never as
// decomposed jamo char keys.

const OfficeEditor = {
  mounted() {
    this.pages = new Map() // pageNumber -> { section, canvas, overlay, w, h }
    this.caret = null // { page, x, y, height } in page-local CSS px
    this.composing = false
    this.docType = "text"
    this.partCount = 1
    this.pageCount = 0
    this.caretBlinkOn = true
    // Page raster dims (px) keyed by page number, from the first tile that lands.
    this.pageDims = new Map()

    this.pageStack = this.el.querySelector("[data-role='office-editor-pages']")
    this.imeProxy = this.el.querySelector("[data-role='office-editor-ime-proxy']")

    this.handleEvent("office_edit_open", payload => this.onOpen(payload))
    this.handleEvent("office_edit_tile", payload => this.onTile(payload))
    this.handleEvent("office_edit_caret", payload => this.onCaret(payload))
    this.handleEvent("office_edit_saved", payload => this.onSaved(payload))

    this.onMouseDown = e => this.onCanvasMouseDown(e)
    this.el.addEventListener("mousedown", this.onMouseDown)

    this.bindEditing()

    this.blink = setInterval(() => {
      this.caretBlinkOn = !this.caretBlinkOn
      if (this.caret) this.drawCaret(this.caret)
    }, 530)

    // Expose for verification (Tidewave browser_eval / canvas pixel hashing).
    window.__officeEditor = this
  },

  destroyed() {
    if (this.blink) clearInterval(this.blink)
    this.el.removeEventListener("mousedown", this.onMouseDown)
    this.unbindEditing()
    if (window.__officeEditor === this) window.__officeEditor = null
  },

  // ─── Server events ─────────────────────────────────────────────────────────

  onOpen(payload) {
    this.docType = payload.doc_type || "text"
    this.partCount = Math.max(1, Number(payload.part_count) || 1)
    // For a text doc the "pages" come from tiles; seed at least one page box so
    // the canvas exists immediately. Presentations have one box per slide/part.
    const initial = this.docType === "presentation" ? this.partCount : 1
    this.pageCount = Math.max(initial, Number(payload.page_count) || initial)
    this.buildPageStack(this.pageCount)
    // Ask the server to paint the first page/part.
    this.requestPaint(1)
  },

  // A painted PNG tile for a page. Place it at its page-local px (x,y) inside
  // the page box; size to its CSS px footprint (tile_w x tile_h). The backing
  // PNG (width x height px) may be 2x for crispness — CSS scales it down.
  onTile(tile) {
    const page = Number(tile.page) || 1
    this.ensurePage(page, tile)
    const entry = this.pages.get(page)
    if (!entry) return
    const img = new Image()
    img.onload = () => {
      const ctx = entry.canvas.getContext("2d")
      if (!ctx) return
      // Backing store is the page box at devicePixelRatio. Draw the tile at its
      // page-local px box (tile.x, tile.y, tile.tile_w, tile.tile_h).
      const s = entry.scale
      ctx.drawImage(
        img,
        Math.round((tile.x || 0) * s),
        Math.round((tile.y || 0) * s),
        Math.round((tile.tile_w || entry.w) * s),
        Math.round((tile.tile_h || entry.h) * s)
      )
      // The page canvas was repainted in this region; redraw the caret if it
      // sits on this page.
      if (this.caret && this.caret.page === page) this.drawCaret(this.caret)
    }
    img.src = tile.src
  },

  onCaret(caret) {
    this.caret = {
      page: Number(caret.page) || 1,
      x: Number(caret.x) || 0,
      y: Number(caret.y) || 0,
      height: Number(caret.height) || 16
    }
    this.caretBlinkOn = true
    this.drawCaret(this.caret)
    this.anchorProxy()
    if (this.imeProxy) this.imeProxy.focus({ preventScroll: true })
  },

  onSaved(payload) {
    this.el.dataset.saveState = payload && payload.ok ? "saved" : "error"
  },

  // ─── Page DOM (canvas per page, overlay per page) ───────────────────────────

  buildPageStack(count) {
    if (!this.pageStack) return
    this.pages.clear()
    this.pageStack.replaceChildren()
    for (let p = 1; p <= count; p++) this.createPage(p)
  },

  createPage(page, dims) {
    if (this.pages.has(page)) return this.pages.get(page)
    // Default A4-portrait box until the first tile reports real dims.
    const w = (dims && dims.w) || 794
    const h = (dims && dims.h) || 1123

    const section = document.createElement("section")
    section.dataset.role = "office-editor-page"
    section.dataset.pageNumber = String(page)
    section.className = "relative bg-white shadow-sm border border-base-300"
    section.style.cssText = `width:${w}px;max-width:100%;aspect-ratio:${w} / ${h};position:relative`

    const dpr = window.devicePixelRatio || 1
    const canvas = document.createElement("canvas")
    canvas.dataset.role = "office-editor-canvas"
    canvas.width = Math.round(w * dpr)
    canvas.height = Math.round(h * dpr)
    canvas.style.cssText = "display:block;width:100%;height:100%"
    // White base so a blank page reads as paper before tiles land.
    const ctx = canvas.getContext("2d")
    if (ctx) {
      ctx.fillStyle = "#ffffff"
      ctx.fillRect(0, 0, canvas.width, canvas.height)
    }

    const overlay = document.createElement("canvas")
    overlay.dataset.role = "office-editor-caret-overlay"
    overlay.width = canvas.width
    overlay.height = canvas.height
    overlay.style.cssText =
      "position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none"

    section.appendChild(canvas)
    section.appendChild(overlay)
    this.pageStack.appendChild(section)

    const entry = { section, canvas, overlay, w, h, scale: dpr }
    this.pages.set(page, entry)
    return entry
  },

  // Resize a page box to match the tile's reported page dims (so a text doc's
  // single tall page sizes correctly once we know its raster footprint).
  ensurePage(page, tile) {
    let entry = this.pages.get(page)
    if (!entry) entry = this.createPage(page)
    // The full-part paint reports the page's px footprint via tile_w/tile_h when
    // it covers the whole page (x==0,y==0). Use it to size the box once.
    if ((tile.x || 0) === 0 && (tile.y || 0) === 0 && tile.tile_w && tile.tile_h) {
      const w = Math.round(tile.tile_w)
      const h = Math.round(tile.tile_h)
      if (w > 0 && h > 0 && (entry.w !== w || entry.h !== h) && !this.pageDims.has(page)) {
        this.pageDims.set(page, { w, h })
        this.resizePage(entry, w, h)
      }
    }
  },

  resizePage(entry, w, h) {
    const dpr = window.devicePixelRatio || 1
    entry.w = w
    entry.h = h
    entry.scale = dpr
    entry.section.style.cssText = `width:${w}px;max-width:100%;aspect-ratio:${w} / ${h};position:relative`
    entry.canvas.width = Math.round(w * dpr)
    entry.canvas.height = Math.round(h * dpr)
    entry.overlay.width = entry.canvas.width
    entry.overlay.height = entry.canvas.height
    const ctx = entry.canvas.getContext("2d")
    if (ctx) {
      ctx.fillStyle = "#ffffff"
      ctx.fillRect(0, 0, entry.canvas.width, entry.canvas.height)
    }
  },

  pageSection(page) {
    const entry = this.pages.get(page)
    return entry && entry.section
  },

  // ─── Input ───────────────────────────────────────────────────────────────

  // mousedown on a page -> page-local px -> hit_test.
  onCanvasMouseDown(event) {
    if (event.button !== 0) return
    const section = event.target.closest("[data-role='office-editor-page']")
    if (!section) return
    const page = Number(section.dataset.pageNumber) || 1
    const canvas = section.querySelector("[data-role='office-editor-canvas']")
    if (!canvas) return
    const rect = canvas.getBoundingClientRect()
    // page-local CSS px (the LOK hit_test coordinate space @96dpi).
    const x = ((event.clientX - rect.left) / rect.width) * this.pageBoxWidth(page)
    const y = ((event.clientY - rect.top) / rect.height) * this.pageBoxHeight(page)

    this.pushEvent("office.edit.hit_test", { page, x, y })

    if (this.imeProxy) {
      event.preventDefault()
      this.imeProxy.focus({ preventScroll: true })
    }
  },

  pageBoxWidth(page) {
    const e = this.pages.get(page)
    return (e && e.w) || 794
  },
  pageBoxHeight(page) {
    const e = this.pages.get(page)
    return (e && e.h) || 1123
  },

  bindEditing() {
    if (!this.imeProxy) return
    this.onInput = e => this.handleInput(e)
    this.onCompStart = () => { this.composing = true }
    this.onCompUpdate = e => this.handleCompositionUpdate(e)
    this.onCompEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)

    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
  },

  unbindEditing() {
    if (!this.imeProxy) return
    this.imeProxy.removeEventListener("input", this.onInput)
    this.imeProxy.removeEventListener("compositionstart", this.onCompStart)
    this.imeProxy.removeEventListener("compositionupdate", this.onCompUpdate)
    this.imeProxy.removeEventListener("compositionend", this.onCompEnd)
    this.imeProxy.removeEventListener("keydown", this.onKeyDown)
  },

  // Plain (non-composing) text — ASCII / paste. Korean goes via composition*.
  handleInput(event) {
    if (event.isComposing) return
    const type = event.inputType || ""
    if (
      type === "insertText" ||
      type === "insertFromPaste" ||
      type === "insertReplacementText"
    ) {
      const data = event.data != null ? event.data : this.imeProxy.value
      if (data) {
        for (const ch of data) this.pushEvent("office.edit.key", { text: ch, key: ch })
      }
    }
    this.imeProxy.value = ""
  },

  // Korean / composing: send the in-progress preedit so LOK shows it live, then
  // commit the final composed string on compositionend.
  handleCompositionUpdate(event) {
    const str = event.data || ""
    this.pushEvent("office.edit.ime", { preedit: str })
  },

  handleCompositionEnd(event) {
    this.composing = false
    const str = event.data || ""
    if (str) this.pushEvent("office.edit.ime", { commit: str })
    else this.pushEvent("office.edit.ime", { end: true })
    this.imeProxy.value = ""
  },

  handleKeyDown(event) {
    if (event.isComposing) return

    // Ctrl/Cmd+S -> save.
    if ((event.metaKey || event.ctrlKey) && (event.key === "s" || event.key === "S")) {
      event.preventDefault()
      this.pushEvent("office.edit.save", {})
      return
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return

    const CONTROL = [
      "Backspace", "Delete", "Enter", "Tab", "Escape",
      "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight",
      "Home", "End", "PageUp", "PageDown"
    ]
    if (CONTROL.includes(event.key)) {
      event.preventDefault()
      this.pushEvent("office.edit.key", { key: event.key })
    }
    // Printable single chars flow through the `input` event (handleInput), so we
    // don't double-send them here.
  },

  // ─── Caret + viewport ──────────────────────────────────────────────────────

  drawCaret(caret) {
    const entry = this.pages.get(caret.page)
    if (!entry) return
    const ctx = entry.overlay.getContext("2d")
    if (!ctx) return
    ctx.clearRect(0, 0, entry.overlay.width, entry.overlay.height)
    if (!this.caretBlinkOn) return
    const s = entry.scale
    ctx.fillStyle = "#1d4ed8"
    ctx.fillRect(caret.x * s, caret.y * s, Math.max(1.5 * s, 1), (caret.height || 16) * s)
  },

  anchorProxy() {
    if (!this.imeProxy || !this.caret) return
    const entry = this.pages.get(this.caret.page)
    if (!entry) return
    const cr = entry.canvas.getBoundingClientRect()
    const hostRect = this.el.getBoundingClientRect()
    const cssPerPage = cr.width / entry.w
    const left = cr.left - hostRect.left + this.el.scrollLeft + this.caret.x * cssPerPage
    const top = cr.top - hostRect.top + this.el.scrollTop + this.caret.y * cssPerPage
    this.imeProxy.style.left = `${Math.round(left)}px`
    this.imeProxy.style.top = `${Math.round(top)}px`
    this.imeProxy.style.height = `${Math.max(12, Math.round((this.caret.height || 16) * cssPerPage))}px`
  },

  // Ask the server to paint a page in full (used on open / part switch). The
  // server clips to the part's real extent, so passing a generous box is safe.
  requestPaint(page) {
    this.pushEvent("office.edit.paint", {
      page,
      x: 0,
      y: 0,
      width: this.pageBoxWidth(page),
      height: this.pageBoxHeight(page)
    })
  }
}

export { OfficeEditor }
