if Application.compile_env(:contract, :test_auth, false) do
  defmodule Contract.E2E do
    @moduledoc """
    Test-only cleanup helpers for Playwright e2e runs against the public
    sprite URL. The Playwright runner calls `POST /test/reset` between
    scenarios (route gated by `Application.compile_env(:contract, :test_auth)`),
    which delegates here.

    The reset is **idempotent** and tolerates missing tables — Studio Wave
    3C1 will introduce `matters` and `documents`; until those migrations
    exist this still works (it just no-ops the corresponding deletes).
    Persona users created by `Contract.PersonaFactory` are *not* deleted by
    default — each test mints fresh users with unique emails so they don't
    collide.
    """

    alias Contract.Repo

    @doc """
    Deletes everything scoped to the `e2e` matter (and its documents,
    changes, snapshots, revoke_requests). Tolerates missing tables so we
    can land this controller now and wire in Studio rows later without a
    cross-cutting migration dance.
    """
    @spec reset!() :: :ok
    def reset! do
      safe_query!(
        "DELETE FROM changes WHERE matter_id IN (SELECT id FROM matters WHERE name = 'e2e')"
      )

      safe_query!(
        "DELETE FROM snapshots WHERE matter_id IN (SELECT id FROM matters WHERE name = 'e2e')"
      )

      safe_query!(
        "DELETE FROM revoke_requests WHERE matter_id IN (SELECT id FROM matters WHERE name = 'e2e')"
      )

      safe_query!(
        "DELETE FROM documents WHERE matter_id IN (SELECT id FROM matters WHERE name = 'e2e')"
      )

      safe_query!("DELETE FROM matters WHERE name = 'e2e'")

      :ok
    end

    @doc """
    Wipes all user rows created by the persona factory in the public-URL
    e2e run. Only called explicitly (not part of `reset!/0`) since most
    scenarios prefer to keep the actor user alive across the spec.
    """
    @spec reset_personas!() :: :ok
    def reset_personas! do
      safe_query!(
        "DELETE FROM users_tokens WHERE user_id IN (SELECT id FROM users WHERE email ~ '^(lawyer|paralegal|agent-sup|viewer|admin)-[0-9]+@example\\.com$')"
      )

      safe_query!(
        "DELETE FROM users WHERE email ~ '^(lawyer|paralegal|agent-sup|viewer|admin)-[0-9]+@example\\.com$'"
      )

      :ok
    end

    defp safe_query!(sql) do
      try do
        Repo.query!(sql)
        :ok
      rescue
        e in Postgrex.Error ->
          case e.postgres do
            %{code: :undefined_table} -> :ok
            _ -> reraise(e, __STACKTRACE__)
          end
      end
    end
  end
end
