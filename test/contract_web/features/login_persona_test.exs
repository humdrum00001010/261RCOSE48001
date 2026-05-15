defmodule ContractWeb.LoginPersonaTest do
  @moduledoc """
  Wallaby smoke for the persona harness — one feature per canonical
  persona. Each test signs the persona in through the gen.auth password
  form on `/users/log-in` (the most stable Phoenix page) and asserts the
  resulting page renders.

  This is the acceptance bar for the Wave 3 persona harness: when Wave
  3C1 lands the real Studio LiveView, it inherits this exact `FeatureCase`
  + `PersonaFactory` plumbing. Tagged `:browser` so the default
  `mix test` run stays Chromium-free.
  """

  use ContractWeb.FeatureCase, async: false

  @moduletag :browser

  # We define one `feature` per persona. We can't use `for persona <- ...`
  # with `feature "...#{persona}..."` directly: the `feature` macro
  # re-quotes its title arg into the generated function body, and
  # Elixir 1.18+'s stricter variable checker would flag the loop's
  # `persona` binding as undefined in that quoted scope. Listing them
  # explicitly keeps the AST literal-only and matches the canonical
  # five-persona set published by `Contract.PersonaFactory.personas/0`
  # (verified in `test/contract/persona_factory_test.exs`).

  feature "login page renders for lawyer persona", %{session: session} do
    session
    |> PersonaFactory.sign_in(:lawyer)
    |> assert_has(Query.css("body"))
  end

  feature "login page renders for paralegal persona", %{session: session} do
    session
    |> PersonaFactory.sign_in(:paralegal)
    |> assert_has(Query.css("body"))
  end

  feature "login page renders for agent_supervised persona", %{session: session} do
    session
    |> PersonaFactory.sign_in(:agent_supervised)
    |> assert_has(Query.css("body"))
  end

  feature "login page renders for viewer persona", %{session: session} do
    session
    |> PersonaFactory.sign_in(:viewer)
    |> assert_has(Query.css("body"))
  end

  feature "login page renders for admin persona", %{session: session} do
    session
    |> PersonaFactory.sign_in(:admin)
    |> assert_has(Query.css("body"))
  end
end
