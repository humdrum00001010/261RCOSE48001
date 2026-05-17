defmodule ContractWeb.LegacyRedirectController do
  @moduledoc """
  Backwards-compat redirects for routes that pre-date the 2026-05-15
  Document-pivot (SPEC.md §4).

  Historically, the Studio mounted at
  `/matters/:matter_id/documents/:document_id`. After the v33 pivot,
  the canonical URL is `/studio/:document_id`. Older links (bookmarks,
  emails, Slack unfurls, agent transcripts) must continue to resolve.

  Permanent (301) so caches, link previews, and Slack/Notion unfurls
  can pin the new URL.
  """

  use ContractWeb, :controller

  @doc """
  GET /matters/:matter_id/documents/:document_id
    → 301 /studio/:document_id

  The matter_id is dropped; the document id is the canonical route key.
  """
  def matter_document(conn, %{"document_id" => document_id}) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/studio/#{document_id}")
  end
end
