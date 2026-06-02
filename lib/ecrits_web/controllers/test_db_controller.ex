if Application.compile_env(:ecrits, :test_auth, false) do
  defmodule EcritsWeb.TestDbController do
    @moduledoc """
    Retired DB inspection endpoints kept as DB-free test-auth routes.
    """

    use EcritsWeb, :controller

    plug :gate_test_auth

    def changes(conn, %{"document_id" => doc_id}) do
      json(conn, %{ok: false, retired: true, document_id: doc_id, changes: []})
    end

    def documents(conn, _params) do
      json(conn, %{ok: false, retired: true, documents: []})
    end

    def oban_jobs(conn, params) do
      queue = Map.get(params, "queue", "default")
      json(conn, %{ok: false, retired: true, queue: queue, jobs: []})
    end

    def seed_document(conn, _params) do
      conn
      |> put_status(:gone)
      |> json(%{ok: false, retired: true, error: "db_retired"})
    end

    defp gate_test_auth(conn, _opts) do
      if Application.get_env(:ecrits, :test_auth, false) do
        conn
      else
        conn |> send_resp(404, "") |> halt()
      end
    end
  end
end
