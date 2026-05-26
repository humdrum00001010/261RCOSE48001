if Application.compile_env(:contract, :test_auth, false) do
  defmodule ContractWeb.TestDbController do
    @moduledoc """
    Playwright-only DB inspection routes. Returns JSON snapshots of Studio
    rows (`changes`, `documents`, `oban_jobs`) so the
    Playwright runner can assert backend state from across the public sprite
    URL without standing up an Ecto connection.

    Gated behind `Application.compile_env(:contract, :test_auth, false)`:
    the entire module elides at compile-time in `:prod`, and the runtime
    plug also re-checks (defence in depth) — production routes 404.

    Endpoints (all GET, all under `/test/db`):

      * `GET /test/db/changes/:document_id`
        → list of changes for the doc, ordered by `result_revision asc`.
      * `GET /test/db/documents`
        → list of documents (may be empty if migration not yet present).
      * `GET /test/db/oban_jobs?queue=<queue>`
        → list of Oban jobs for the given queue (state, args, attempts).

    All endpoints tolerate missing tables (return `[]`) so the controller
    can ship ahead of `documents` migrations.
    """

    use ContractWeb, :controller

    alias Contract.{Accounts, Context, Documents, PersonaFactory, Repo}

    plug :gate_test_auth

    @doc """
    `GET /test/db/changes/:document_id`
    """
    def changes(conn, %{"document_id" => doc_id}) do
      rows =
        safe_query!(
          """
          SELECT id::text, command_kind, result_revision, base_revision, status,
                 actor_type, idempotency_key, inserted_at
            FROM changes
           WHERE document_id = $1
           ORDER BY result_revision ASC
          """,
          [cast_uuid(doc_id)]
        )

      json(conn, %{ok: true, document_id: doc_id, changes: rows})
    end

    @doc """
    `GET /test/db/documents`

    Returns every row from the `documents` table. The Studio Wave 3C1
    migration may or may not be present yet — when it isn't, the call
    returns `[]` instead of 500-ing, so Playwright specs that depend on
    `documents` rows can `test.skip(rows.length === 0, ...)` and move on.
    """
    def documents(conn, _params) do
      rows =
        safe_query!(
          """
          SELECT id::text, owner_id::text, title, type_key,
                 status, latest_revision, inserted_at
            FROM documents
           ORDER BY inserted_at DESC
           LIMIT 200
          """,
          []
        )

      json(conn, %{ok: true, documents: rows})
    end

    @doc """
    `GET /test/db/oban_jobs?queue=<queue>`
    """
    def oban_jobs(conn, params) do
      queue = Map.get(params, "queue", "default")

      rows =
        safe_query!(
          """
          SELECT id, queue, worker, args, state, attempt, max_attempts,
                 inserted_at, completed_at, discarded_at, cancelled_at,
                 errors
            FROM oban_jobs
           WHERE queue = $1
           ORDER BY id DESC
           LIMIT 50
          """,
          [queue]
        )

      json(conn, %{ok: true, queue: queue, jobs: rows})
    end

    @doc """
    `POST /test/db/documents`

    Seeds an owner-scoped Document for the current Playwright session.

    Optional body params:
      * `title` — defaults to `"E2E document <n>"`.
      * `type_key` — defaults to `"nda_v1"`.

    Seeded documents are tagged with `%{"e2e" => true}` metadata so
    `/test/reset` can clean them up without relying on legacy Matters.
    """
    def seed_document(conn, params) do
      scope = ensure_scope!(conn)

      attrs = %{
        "title" =>
          Map.get(params, "title") || "E2E document #{System.unique_integer([:positive])}",
        "type_key" => Map.get(params, "type_key") || "nda_v1",
        "metadata" => %{"e2e" => true}
      }

      case Documents.create(scope, attrs) do
        {:ok, doc} ->
          json(conn, %{
            ok: true,
            id: doc.id,
            owner_id: doc.owner_id,
            type_key: doc.type_key,
            title: doc.title
          })

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(422) |> json(%{ok: false, errors: format_errors(cs)})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{ok: false, error: inspect(reason)})
      end
    end

    # ----------------------------------------------------------------------------
    # internals
    # ----------------------------------------------------------------------------

    # Executes `sql` with `params`. Returns a list of column-keyed maps so
    # the JSON encoder can emit a sensible shape. Tolerates `undefined_table`
    # by returning `[]` — useful while `documents` migrations are
    # still in flight.
    defp safe_query!(sql, params) do
      try do
        %{columns: cols, rows: rows} = Repo.query!(sql, params)

        for row <- rows do
          cols
          |> Enum.zip(row)
          |> Enum.into(%{}, fn {k, v} -> {k, jsonify(v)} end)
        end
      rescue
        e in Postgrex.Error ->
          case e.postgres do
            %{code: :undefined_table} -> []
            %{code: :invalid_text_representation} -> []
            _ -> reraise(e, __STACKTRACE__)
          end
      end
    end

    # `Repo.query!/2` returns raw values that JSON can't always encode —
    # DateTimes round-trip as ISO8601 strings, UUIDs come back as 16-byte
    # binaries (cast via `::text` in SQL when we want strings), maps are
    # already encodable.
    defp jsonify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp jsonify(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
    defp jsonify(%Date{} = d), do: Date.to_iso8601(d)
    defp jsonify(v) when is_list(v), do: Enum.map(v, &jsonify/1)
    defp jsonify(v) when is_map(v), do: Map.new(v, fn {k, vv} -> {k, jsonify(vv)} end)
    defp jsonify(v), do: v

    # Postgres `WHERE document_id = $1` against a `binary_id` column needs
    # a binary UUID. If the caller sends a non-UUID string we want a clean
    # `[]` response (not a 500); `Ecto.UUID.dump/1` returns `:error` for
    # malformed strings — handle that by returning a sentinel that won't
    # match any row.
    defp cast_uuid(s) when is_binary(s) do
      case Ecto.UUID.dump(s) do
        {:ok, bin} -> bin
        :error -> <<0::128>>
      end
    end

    # Build a `%Context{}` for the seeder. Prefers the real signed-in
    # user pulled from the session cookie set by
    # `ContractWeb.TestAuthController.sign_in/2`. If no session is
    # present (Playwright forgot to sign in first), we mint a throwaway
    # lawyer persona so the route still produces a useful owner-scoped row.
    defp ensure_scope!(conn) do
      case current_scope_from_session(conn) do
        %Context{user: %{}} = scope -> scope
        _ -> fallback_scope()
      end
    end

    defp current_scope_from_session(conn) do
      case get_session(conn, :user_token) do
        nil ->
          nil

        token ->
          case Accounts.get_user_by_session_token(token) do
            {user, _inserted_at} -> Context.for_user(user)
            _ -> nil
          end
      end
    rescue
      # `fetch_session/2` may not have been called (e.g. test forgot to
      # init_test_session). Treat as "no session" rather than crashing.
      ArgumentError -> nil
    end

    # Build a throwaway persona; retry on the well-known
    # `unsafe_validate_unique` email-collision flake. `PersonaFactory`'s
    # random suffix space is ~10k, so parallel Playwright workers
    # occasionally collide. After a handful of retries the suffix has
    # rerolled enough times that a second collision is vanishingly
    # likely.
    defp fallback_scope, do: fallback_scope(5)

    defp fallback_scope(0) do
      raise "fallback_scope: PersonaFactory.build/1 collided 5 times in a row"
    end

    defp fallback_scope(retries_left) do
      %{user: user} = PersonaFactory.build(:lawyer)
      Context.for_user(user)
    rescue
      MatchError -> fallback_scope(retries_left - 1)
    end

    # Converts an Ecto.Changeset's errors to a JSON-friendly map of
    # `field -> [messages]`.
    defp format_errors(%Ecto.Changeset{} = cs) do
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)
    end

    defp gate_test_auth(conn, _opts) do
      if Application.get_env(:contract, :test_auth, false) do
        conn
      else
        conn |> send_resp(404, "") |> halt()
      end
    end
  end
end
