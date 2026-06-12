defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalMarkdownEditor do
  @moduledoc """
  Editable Markdown document surface with a live MDEx-rendered preview.

  Markdown is plain text (no engine, no WASM, no LibreOffice): the canonical
  workspace `.md`/`.markdown` file is loaded as text into an editable `<textarea>`
  source pane, and a live preview shows the GFM render. The render reuses the
  shared MDEx helper (`EcritsWeb.Markdown.to_safe_html/1`) — the same renderer the
  chat rail uses — and is styled with the existing `.chat-markdown` CSS.

  The surface is a SINGLE pane: a header toggle button switches between PREVIEW
  and SOURCE (mirroring the usual markdown-editor affordance) rather than showing
  them side-by-side. Both panes stay mounted in the DOM (the toggle only flips
  visibility, client-side, via `Phoenix.LiveView.JS`) so the live MDEx preview
  keeps re-rendering while you edit and the source textarea's caret/selection are
  never torn down.

  The `MarkdownEditor` hook (assets/js/markdown_editor.js) owns the source
  textarea:

    * input -> debounced `markdown.source_changed` -> server re-renders the
      preview (`@preview_html`) -> LiveView diffs the preview pane
    * Ctrl/Cmd+S -> `markdown.save` -> server `Document.save` (atomic canonical write)

  The textarea is `phx-update="ignore"` so LiveView diffs never clobber the user's
  caret/selection while typing; the hook seeds it from `data-initial-source`.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :source, :string, default: ""
  attr :preview_html, :any, default: ""

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex h-full min-h-0 flex-col overflow-hidden bg-base-100"
      data-component="canvas-local-markdown-editor"
      data-renderer="markdown"
      data-role="markdown-editor"
      data-view="preview"
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
    >
      <%!-- Header with the single PREVIEW <-> SOURCE toggle. The button flips
            which pane is visible (client-side; no server round-trip) and swaps
            its own label — "Source" while previewing, "Preview" while editing. --%>
      <header class="flex min-h-8 shrink-0 items-center justify-between border-b border-base-300 bg-base-200/60 px-3 text-[11px] font-medium uppercase tracking-wide text-base-content/55">
        <span data-role="markdown-editor-mode">
          <span data-mode-label="preview">Preview</span>
          <span data-mode-label="source" class="hidden">Source</span>
        </span>
        <button
          type="button"
          data-role="markdown-editor-toggle"
          phx-click={toggle_markdown_view(@id)}
          class="rounded px-2 py-0.5 text-[11px] font-medium uppercase tracking-wide text-base-content/70 hover:bg-base-300/60 hover:text-base-content"
        >
          <span data-toggle-label="preview" title="Edit source">
            <.icon name="hero-code-bracket" class="size-4 align-middle" />
          </span>
          <span data-toggle-label="source" class="hidden" title="Show preview">
            <.icon name="hero-eye" class="size-4 align-middle" />
          </span>
        </button>
      </header>

      <%!-- Source pane: editable plain-text markdown. The hook seeds the value
            from data-initial-source, debounces input -> markdown.source_changed,
            and binds Ctrl/Cmd+S -> markdown.save. phx-update="ignore" keeps the
            user's caret stable across preview diffs. Hidden until the toggle
            switches to SOURCE; stays mounted so the hook isn't torn down. --%>
      <textarea
        id={"#{@id}-source"}
        data-role="markdown-editor-source"
        data-initial-source={@source}
        phx-hook="MarkdownEditor"
        phx-update="ignore"
        spellcheck="false"
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
        class="hidden min-h-0 flex-1 resize-none border-0 bg-base-100 p-4 font-mono text-[13px] leading-relaxed text-base-content outline-none focus:outline-none"
      ></textarea>

      <%!-- Preview pane: live Observex render of the current source (GFM +
            math/TikZ tex-islands). Styled with the shared .chat-markdown CSS
            (full-width here). Visible by default. The ObservexPreview hook
            re-renders the islands (MathJax/TikZJax) after every diff. --%>
      <div
        id={"#{@id}-preview"}
        data-role="markdown-editor-preview"
        phx-hook="ObservexPreview"
        class="chat-markdown min-h-0 flex-1 overflow-auto p-6 text-[15px] leading-[1.7]"
      >
        {@preview_html}
      </div>
    </div>
    """
  end

  # Single-pane PREVIEW <-> SOURCE toggle, run entirely client-side so it never
  # touches the LiveView/document state: flip the `hidden` utility on the two
  # panes (and the mode/toggle labels). Toggling the `hidden` class — rather than
  # JS.toggle's inline `display` — is what lets the flex panes (`flex-1`) keep
  # their natural display when shown.
  defp toggle_markdown_view(id) do
    %JS{}
    |> JS.toggle_class("hidden", to: "##{id}-source")
    |> JS.toggle_class("hidden", to: "##{id}-preview")
    |> JS.toggle_class("hidden", to: "##{id} [data-mode-label='preview']")
    |> JS.toggle_class("hidden", to: "##{id} [data-mode-label='source']")
    |> JS.toggle_class("hidden", to: "##{id} [data-toggle-label='preview']")
    |> JS.toggle_class("hidden", to: "##{id} [data-toggle-label='source']")
  end
end
