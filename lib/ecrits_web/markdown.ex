defmodule EcritsWeb.Markdown do
  @moduledoc """
  Shared markdown -> HTML renderers.

  Two entry points with different trust envelopes:

    * `to_safe_html/1` — plain GFM via MDEx, raw HTML escaped. Used by the
      chat rail (`ChatRail.markdown_body`) for agent/user message bodies.

    * `to_preview_html/1` — Observex composite render (GFM + `$...$` /
      `$$...$$` math + fenced `tikz` blocks) for the markdown document
      preview (`LocalMarkdownEditor`). Source raw HTML is still escaped by
      Observex; only its generated `<tex-island>` markup is live, and the
      `ObservexPreview` hook renders those islands client-side (MathJax /
      TikZJax from /observex/ assets).

  On any parse error both fall back to the plain text rather than crash the
  render.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  @doc """
  Render markdown `body` to a `Phoenix.HTML.safe` value of sanitized HTML.

  Returns an empty string for non-binary/empty input.
  """
  @spec to_safe_html(term()) :: Phoenix.HTML.safe() | String.t()
  def to_safe_html(body) when is_binary(body) and body != "" do
    Phoenix.HTML.raw(MDEx.to_html!(body, extension: @extension))
  rescue
    _ -> body
  end

  def to_safe_html(_body), do: ""

  @doc """
  Render markdown `body` for the document preview, with math/TikZ islands.

  Returns an empty string for non-binary/empty input.
  """
  @spec to_preview_html(term()) :: Phoenix.HTML.safe() | String.t()
  def to_preview_html(body) when is_binary(body) and body != "" do
    Phoenix.HTML.raw(Observex.render_body(body))
  rescue
    _ -> body
  end

  def to_preview_html(_body), do: ""
end
