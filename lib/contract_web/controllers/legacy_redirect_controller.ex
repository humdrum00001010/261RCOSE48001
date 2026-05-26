defmodule ContractWeb.LegacyRedirectController do
  @moduledoc """
  Backwards-compat redirects for renamed browser routes.
  """

  use ContractWeb, :controller

  @doc """
  GET /dashboard → 301 /storage

  The authenticated home was renamed from "Dashboard" (대시보드) to
  "Storage" (보관함) on 2026-05-17 — the surface is a document library,
  not a metrics dashboard. Old bookmarks and email links must still
  resolve to the canonical /storage URL.
  """
  def dashboard(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/storage")
  end
end
