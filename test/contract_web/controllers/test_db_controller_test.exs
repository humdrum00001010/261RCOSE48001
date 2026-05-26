defmodule ContractWeb.TestDbControllerTest do
  @moduledoc """
  Plumbing tests for the Playwright DB inspection routes. The semantic
  acceptance bar still lives in `test/e2e/tests/studio/*.spec.ts` — these
  ExUnit cases only prove that

    * the routes are reachable when `:test_auth` is on (the test env);
    * each endpoint returns the documented `{ok, ...}` JSON envelope;
    * unknown documents return an empty list (not 500);
    * missing tables (`documents`) are tolerated and yield `[]`.

  The compile-time prod gating is asserted by the existence of the
  `if Application.compile_env(...) do` wrapper in the controller — there
  isn't a portable way to flip a compile-env in ExUnit, so we rely on the
  same pattern already validated by `TestAuthController`.
  """

  use ContractWeb.ConnCase, async: true

  describe "GET /test/db/changes/:document_id" do
    test "returns an empty list for a never-seen document id", %{conn: conn} do
      doc_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/test/db/changes/#{doc_id}")
      assert %{"ok" => true, "document_id" => ^doc_id, "changes" => []} = json_response(conn, 200)
    end

    test "returns [] (not 500) for a malformed document id", %{conn: conn} do
      conn = get(conn, ~p"/test/db/changes/not-a-uuid")
      assert %{"ok" => true, "changes" => []} = json_response(conn, 200)
    end
  end

  describe "GET /test/db/documents" do
    test "returns [] when the documents table is absent (or empty)", %{conn: conn} do
      conn = get(conn, ~p"/test/db/documents")
      assert %{"ok" => true, "documents" => documents} = json_response(conn, 200)
      assert is_list(documents)
    end
  end

  describe "GET /test/db/oban_jobs" do
    test "returns the documented envelope for a queue", %{conn: conn} do
      conn = get(conn, ~p"/test/db/oban_jobs?queue=default")
      assert %{"ok" => true, "queue" => "default", "jobs" => jobs} = json_response(conn, 200)
      assert is_list(jobs)
    end

    test "defaults the queue to 'default' when none is given", %{conn: conn} do
      conn = get(conn, ~p"/test/db/oban_jobs")
      assert %{"ok" => true, "queue" => "default", "jobs" => _} = json_response(conn, 200)
    end
  end
end
