defmodule ContractWeb.TestDbControllerSeedTest do
  @moduledoc """
  Plumbing tests for the Playwright seed routes added to
  `ContractWeb.TestDbController`:

    * `POST /test/db/matters`      — seeds a matter, returns its id.
    * `POST /test/db/documents`    — seeds a document inside the matter.

  These cases focus on the route shape + ACL handshake; the semantic
  contract (Matters.create/Documents.create) is exercised by the
  context-level tests, so we only assert that:

    * a signed-in session can POST and get a 200 + JSON envelope;
    * the matter id round-trips into a document insert;
    * a missing `matter_id` on document insert returns 422;
    * invalid attrs (blank title) return 422 with `errors`.

  The compile-time prod gating is shared with the rest of the
  controller — see the existing `TestDbControllerTest` moduledoc — so
  we don't reassert it here (no portable way to flip a compile_env in
  ExUnit).
  """

  use ContractWeb.ConnCase, async: true

  setup :register_and_log_in_user

  describe "POST /test/db/matters" do
    test "creates a matter and returns its id + name", %{conn: conn} do
      conn = post(conn, ~p"/test/db/matters", %{"name" => "Acme v. Roe — E2E"})

      assert %{"ok" => true, "id" => id, "name" => "Acme v. Roe — E2E"} =
               json_response(conn, 200)

      assert is_binary(id)
      assert byte_size(id) > 0
    end

    test "synthesises a name when none is given", %{conn: conn} do
      conn = post(conn, ~p"/test/db/matters", %{})
      assert %{"ok" => true, "name" => name} = json_response(conn, 200)
      assert is_binary(name)
      assert String.starts_with?(name, "E2E matter")
    end
  end

  describe "POST /test/db/documents" do
    test "creates a document inside an existing matter", %{conn: conn} do
      # First, seed a matter using the seed endpoint itself so the test
      # mirrors the Playwright flow.
      matter_conn = post(conn, ~p"/test/db/matters", %{"name" => "Wave 4 e2e"})
      %{"ok" => true, "id" => matter_id} = json_response(matter_conn, 200)

      doc_conn =
        post(conn, ~p"/test/db/documents", %{
          "matter_id" => matter_id,
          "type_key" => "nda_v1",
          "title" => "First NDA"
        })

      assert %{
               "ok" => true,
               "id" => doc_id,
               "matter_id" => ^matter_id,
               "type_key" => "nda_v1",
               "title" => "First NDA"
             } = json_response(doc_conn, 200)

      assert is_binary(doc_id)
    end

    test "defaults type_key to nda_v1", %{conn: conn} do
      matter_conn = post(conn, ~p"/test/db/matters", %{})
      %{"id" => matter_id} = json_response(matter_conn, 200)

      doc_conn = post(conn, ~p"/test/db/documents", %{"matter_id" => matter_id})

      assert %{"ok" => true, "type_key" => "nda_v1"} = json_response(doc_conn, 200)
    end

    test "returns 422 when matter_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/test/db/documents", %{"title" => "no parent"})

      assert %{"ok" => false, "error" => _} = json_response(conn, 422)
    end

    test "returns 422 for invalid attrs (blank title)", %{conn: conn} do
      matter_conn = post(conn, ~p"/test/db/matters", %{})
      %{"id" => matter_id} = json_response(matter_conn, 200)

      doc_conn =
        post(conn, ~p"/test/db/documents", %{
          "matter_id" => matter_id,
          "title" => "",
          "type_key" => "nda_v1"
        })

      assert %{"ok" => false, "errors" => errors} = json_response(doc_conn, 422)
      assert is_map(errors)
      assert Map.has_key?(errors, "title")
    end
  end
end
