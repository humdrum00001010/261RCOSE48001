defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalOfficeEditor do
  @moduledoc """
  Editable office document surface backed by an in-process LibreOfficeKit (LOK)
  edit session.

  This mirrors the HWP editor's UX shape (canvas-per-page, click->caret,
  type->edit, Korean IME via a hidden proxy, real-time repaint) — but the page
  tiles are painted by the SERVER's LOK `paintTile` and pushed as PNGs, not
  rendered client-side. The `OfficeEditor` hook (assets/js/office_editor.js)
  owns the DOM under `[data-role='office-editor-pages']`:

    * server `office_edit_open` -> build page canvases + request the first paint
    * click -> `office.edit.hit_test` -> server `office_edit_caret`
    * keydown -> `office.edit.key`; IME -> `office.edit.ime` -> server repaints
      the LOK-invalidated tiles -> `office_edit_tile` -> the hook draws the PNG
    * Ctrl+S -> `office.edit.save`

  It is only rendered when the LiveView has a live edit session
  (`@local_hwp_stream_renderer == :libreofficex_edit`); otherwise the read-only
  `LocalOfficeTiles` surface is shown.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :local_document_revision, :integer, required: true
  attr :loading?, :boolean, default: false

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-base-200"
      data-component="canvas-local-office-editor"
      data-renderer="libreofficex-lok-edit"
      data-role="office-editor-viewer"
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-local-document-revision={@local_document_revision}
      phx-hook="OfficeEditor"
    >
      <div
        :if={@loading?}
        id={"#{@id}-loading"}
        data-role="office-editor-loading"
        class="border-b border-base-300 bg-base-100 px-5 py-2 text-sm text-base-content/60"
      >
        Opening document for editing...
      </div>

      <%!-- The hook owns this stack (creates one page <canvas> + caret overlay per
            page/slide and paints server-pushed PNG tiles into them). --%>
      <div
        id={"#{@id}-pages"}
        data-role="office-editor-pages"
        class="flex min-h-full flex-col items-center gap-4 py-4"
        phx-update="ignore"
      >
      </div>

      <%!-- Hidden IME proxy: the OS composition target, anchored at the caret so
            the Korean candidate window pops next to the cursor. pointer-events
            none so it never intercepts clicks meant for the page canvas. --%>
      <textarea
        data-role="office-editor-ime-proxy"
        aria-hidden="true"
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
        spellcheck="false"
        class="absolute z-10 m-0 resize-none overflow-hidden border-0 bg-transparent p-0 text-transparent caret-transparent outline-none"
        style="left:0;top:0;width:1px;height:16px;pointer-events:none;opacity:0"
      ></textarea>
    </div>
    """
  end
end
