// Markdown preview tex-island hook.
//
// The preview pane's HTML comes from the server (Observex.render_body via
// EcritsWeb.Markdown.to_preview_html): math/TikZ payloads arrive as inert
// <tex-island> elements. The Observex runtime (/observex/observex.js, a defer
// script loaded before app.js in root.html.heex) renders them client-side
// with MathJax/TikZJax.
//
// window.Observex.render(el) is idempotent and cached by TeX source, so
// calling it after every LiveView diff is cheap: unchanged islands re-render
// synchronously from cache (no flicker), only new TeX compiles.

const ObservexPreview = {
  mounted() {
    this.renderIslands()
  },

  updated() {
    this.renderIslands()
  },

  renderIslands() {
    // Missing runtime (assets not installed / script failed) degrades to the
    // plain GFM render with visible "Rendering" placeholders — don't throw.
    if (!window.Observex) return
    window.Observex.render(this.el).catch(error => {
      console.warn("[observex_preview]", error)
    })
  }
}

export {ObservexPreview}
