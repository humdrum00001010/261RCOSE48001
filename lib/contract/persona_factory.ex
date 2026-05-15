if Application.compile_env(:contract, :test_auth, false) do
  defmodule Contract.PersonaFactory do
    @moduledoc """
    Persona builder for browser-driven e2e tests (Playwright + Wallaby).
    Five canonical personas — every Studio component must ship a Playwright
    scenario covering at least the personas listed in
    `~/.claude/projects/-home-ereignis/memory/feedback-browser-persona-tests.md`.

    Gated behind `Application.compile_env(:contract, :test_auth, false)` so
    the entire module elides in `:prod` builds — `mix compile` in production
    will not even see this file. In `:dev` and `:test` builds the gate is
    `true`, which makes the module compilable and lets:

      * `ContractWeb.TestAuthController` (a `/test/personas/:p/sign_in` route)
        consume the factory to mint a real session cookie for Playwright.
      * `Contract.PersonaFactoryTest` / Wallaby `ContractWeb.FeatureCase`
        consume it from ExUnit.

    `build/1` registers a confirmed user with a known password, returns
    `%{user:, scope:, password:}`. Use inside the SQL.Sandbox (test) or
    against the real Repo (dev/sprite — the cleanup is handled by
    `Contract.E2E.reset!/0`).
    """

    alias Contract.{Accounts, Context, Repo}
    alias Contract.Accounts.User

    @personas %{
      lawyer: %{
        email_prefix: "lawyer",
        perms: ~w(read write commit revoke export type_change agent_run)a
      },
      paralegal: %{
        email_prefix: "paralegal",
        perms: ~w(read write commit revoke type_change agent_run)a
      },
      agent_supervised: %{
        email_prefix: "agent-sup",
        perms: ~w(read write commit revoke agent_run)a
      },
      viewer: %{
        email_prefix: "viewer",
        perms: ~w(read)a
      },
      admin: %{
        email_prefix: "admin",
        perms:
          ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
      }
    }

    @type persona ::
            :lawyer | :paralegal | :agent_supervised | :viewer | :admin

    @default_password "hello world!"

    @doc "Returns the list of canonical persona atoms."
    @spec personas() :: [persona()]
    def personas, do: Map.keys(@personas)

    @doc "Returns the spec map (`%{email_prefix:, perms:}`) for a persona."
    @spec spec(persona()) :: %{email_prefix: String.t(), perms: [atom()]}
    def spec(persona) when is_map_key(@personas, persona), do: Map.fetch!(@personas, persona)

    @doc "Default password assigned to factory-built personas."
    @spec default_password() :: String.t()
    def default_password, do: @default_password

    @doc """
    Builds (but does not sign in) a persona: registers a confirmed user with
    a known password, returns `%{user:, scope:, password:}`.

    Works in any environment where the Repo is up. In the SQL.Sandbox
    (ExUnit) the inserted rows are rolled back at end-of-test; in dev
    (Playwright against the sprite) they persist until
    `Contract.E2E.reset!/0` is called.
    """
    @spec build(persona()) :: %{
            user: User.t(),
            scope: Context.t(),
            password: String.t()
          }
    def build(persona) when is_map_key(@personas, persona) do
      %{email_prefix: prefix, perms: perms} = Map.fetch!(@personas, persona)
      email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} = Accounts.register_user(%{email: email})

      # Confirm + set password directly via the schema — magic-link flow
      # requires Swoosh.Adapters.Test, which only exists in :test.
      {:ok, user} =
        user
        |> User.confirm_changeset()
        |> Repo.update()

      {:ok, user} =
        user
        |> User.password_changeset(%{password: @default_password}, hash_password: true)
        |> Repo.update()

      scope = %Context{Context.for_user(user) | perms: perms}

      %{user: user, scope: scope, password: @default_password}
    end

    if Code.ensure_loaded?(Wallaby.Browser) do
      @doc """
      Wallaby-side helper: builds a persona, drives the Wallaby session
      through the password login form on `/users/log-in`, and returns the
      session post-authentication. Only available when `:wallaby` is loaded
      (test deps), so feature tests can call it.
      """
      @spec sign_in(Wallaby.Session.t(), persona()) :: Wallaby.Session.t()
      def sign_in(session, persona) when is_map_key(@personas, persona) do
        %{user: user, scope: scope, password: password} = build(persona)

        Process.put({__MODULE__, :current}, %{persona: persona, scope: scope, user: user})

        session
        |> Wallaby.Browser.visit("/users/log-in")
        |> Wallaby.Browser.find(Wallaby.Query.css("#login_form_password"), fn form ->
          form
          |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("Email"), with: user.email)
          |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("Password"), with: password)
          |> Wallaby.Browser.click(Wallaby.Query.button("Log in and stay logged in"))
        end)
      end

      @doc """
      Returns the `%Contract.Context{}` for the persona signed in via
      `sign_in/2` from the current test process, or `nil` if none.
      """
      @spec current_context() :: Context.t() | nil
      def current_context do
        case Process.get({__MODULE__, :current}) do
          %{scope: scope} -> scope
          _ -> nil
        end
      end
    end
  end
end
