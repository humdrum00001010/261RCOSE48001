defmodule Contract.PersonaFactoryTest do
  @moduledoc """
  Non-browser checks for `Contract.PersonaFactory`. These run on the default
  `mix test` invocation — the Wallaby `:browser` smoke is in
  `test/contract_web/features/login_persona_test.exs`.
  """

  use Contract.DataCase, async: false

  alias Contract.PersonaFactory

  test "exposes the five canonical personas" do
    assert PersonaFactory.personas() |> Enum.sort() ==
             ~w(admin agent_supervised lawyer paralegal viewer)a
  end

  test "build/1 produces a confirmed user, scope, and password for every persona" do
    for persona <- PersonaFactory.personas() do
      %{user: user, scope: scope, password: password} = PersonaFactory.build(persona)

      assert is_struct(user, Contract.Accounts.User)
      assert user.confirmed_at, "expected #{persona} user to be confirmed"
      assert user.hashed_password, "expected #{persona} user to have a password set"

      assert is_struct(scope, Contract.Context)
      assert scope.user == user
      assert is_list(scope.perms) and scope.perms != []

      assert is_binary(password) and byte_size(password) > 0
    end
  end

  test "spec/1 returns the perm set for each persona" do
    expectations = %{
      lawyer: ~w(read write commit revoke export type_change agent_run)a,
      paralegal: ~w(read write commit revoke type_change agent_run)a,
      agent_supervised: ~w(read write commit revoke agent_run)a,
      viewer: ~w(read)a,
      admin: ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }

    for {persona, perms} <- expectations do
      assert PersonaFactory.spec(persona).perms == perms
    end
  end
end
