defmodule Contract.PersonaFactory do
  @moduledoc """
  Test-only factory that mints Personas + scoped users for Wallaby browser
  sessions. Five canonical personas — every Studio component must ship a
  Wallaby test covering at least the personas listed in
  `~/.claude/projects/-home-ereignis/memory/feedback-browser-persona-tests.md`.

  Usage from a `ContractWeb.FeatureCase`:

      feature "lawyer can do the thing", %{session: session} do
        session
        |> PersonaFactory.sign_in(:lawyer)
        |> assert_has(Wallaby.Query.css("body"))
      end

  `sign_in/2` returns the session, navigated to `/users/log-in` and
  authenticated as a fresh confirmed user with the persona's permission
  set baked into a `Contract.Context{}` (currently stored on the test's
  process dict so component tests can pull it back out without re-querying
  the DB — see `current_context/0`).
  """

  alias Contract.Accounts
  alias Contract.AccountsFixtures
  alias Contract.Context

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
      perms: ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }
  }

  @type persona ::
          :lawyer | :paralegal | :agent_supervised | :viewer | :admin

  @doc """
  Returns the list of canonical persona atoms.
  """
  @spec personas() :: [persona()]
  def personas, do: Map.keys(@personas)

  @doc """
  Returns the spec map (`%{email_prefix:, perms:}`) for a persona.
  """
  @spec spec(persona()) :: %{email_prefix: String.t(), perms: [atom()]}
  def spec(persona) when is_map_key(@personas, persona), do: Map.fetch!(@personas, persona)

  @doc """
  Builds (but does not sign in) a persona: registers a confirmed user with a
  known password, returns the user, a `Contract.Context{}` with the
  persona's permission set, and the password.

  Run inside a DB sandbox (use `ContractWeb.FeatureCase` or
  `Contract.DataCase`); the SQL.Sandbox plug + `metadata_for/2` flow lets
  the same checkout be shared with a Wallaby session.
  """
  @spec build(persona()) :: %{
          user: Accounts.User.t(),
          scope: Context.t(),
          password: String.t()
        }
  def build(persona) when is_map_key(@personas, persona) do
    %{email_prefix: prefix, perms: perms} = Map.fetch!(@personas, persona)
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"
    password = AccountsFixtures.valid_user_password()

    # `user_fixture/1` confirms the account via magic-link.
    user = AccountsFixtures.user_fixture(%{email: email})
    user = AccountsFixtures.set_password(user)

    scope = %Context{Context.for_user(user) | perms: perms}

    %{user: user, scope: scope, password: password}
  end

  @doc """
  Builds a persona, drives the Wallaby session through the password login
  form on `/users/log-in`, and returns the session post-authentication.

  Stores the resulting `%Contract.Context{}` in the test process dict under
  `{Contract.PersonaFactory, :current}` so component tests can recover the
  same scope without a second DB round-trip.
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
