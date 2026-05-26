defmodule ContractWeb.TestDbControllerSeedTest do
  @moduledoc """
  Plumbing tests for the Playwright seed routes added to
  `ContractWeb.TestDbController`:

    * `POST /test/db/documents`    — seeds an owner-scoped document.

  These cases focus on the route shape + ACL handshake; the semantic
  contract (Matters.create/Documents.create) is exercised by the
  context-level tests, so we only assert that:

    * a signed-in session can POST and get a 200 + JSON envelope;
    * the signed-in user owns the document;
    * invalid attrs (blank title) return 422 with `errors`.

  The compile-time prod gating is shared with the rest of the
  controller — see the existing `TestDbControllerTest` moduledoc — so
  we don't reassert it here (no portable way to flip a compile_env in
  ExUnit).
  """

  use ContractWeb.ConnCase, async: true

  alias Contract.{Change, Repo, Snapshot}
  alias Contract.Documents.Document

  setup :register_and_log_in_user

  describe "Studio E2E seed helper surface" do
    test "does not expose normal matter seed helpers or routes" do
      seeds = File.read!(Path.expand("../../e2e/fixtures/seeds.ts", __DIR__))

      refute seeds =~ "seedMatter"
      refute seeds =~ "/test/db/matters"
    end
  end

  describe "POST /test/db/documents" do
    test "creates an owner-scoped document", %{conn: conn, user: user} do
      doc_conn =
        post(conn, ~p"/test/db/documents", %{
          "type_key" => "nda_v1",
          "title" => "First NDA"
        })

      assert %{
               "ok" => true,
               "id" => doc_id,
               "owner_id" => owner_id,
               "type_key" => "nda_v1",
               "title" => "First NDA"
             } = json_response(doc_conn, 200)

      assert is_binary(doc_id)
      assert owner_id == user.id
    end

    test "defaults type_key to nda_v1", %{conn: conn} do
      doc_conn = post(conn, ~p"/test/db/documents", %{})
      assert %{"ok" => true, "type_key" => "nda_v1"} = json_response(doc_conn, 200)
    end

    test "returns 422 for invalid attrs (blank title)", %{conn: conn} do
      doc_conn =
        post(conn, ~p"/test/db/documents", %{
          "title" => "",
          "type_key" => "nda_v1"
        })

      assert %{"ok" => false, "errors" => errors} = json_response(doc_conn, 422)
      assert is_map(errors)
      assert Map.has_key?(errors, "title")
    end
  end

  describe "POST /test/reset" do
    test "deletes document-scoped e2e rows without relying on legacy matter_id", %{
      conn: conn,
      user: user
    } do
      document =
        Repo.insert!(%Document{
          owner_id: user.id,
          title: "E2E reset document",
          type_key: "nda_v1",
          metadata: %{"e2e" => true}
        })

      change =
        Repo.insert!(%Change{
          document_id: document.id,
          command_kind: "insert_clause",
          actor_type: :user,
          actor_id: user.id,
          result_revision: 1
        })

      Repo.insert!(%Snapshot{
        document_id: document.id,
        revision: 1,
        projection: %{"blocks" => []},
        r2_key: "documents/#{document.id}/snapshots/1.json"
      })

      conn = post(conn, ~p"/test/reset", %{})
      assert %{"ok" => true} = json_response(conn, 200)

      refute Repo.get(Document, document.id)
      refute Repo.get(Change, change.id)
      refute Repo.get_by(Snapshot, document_id: document.id, revision: 1)
    end
  end
end
