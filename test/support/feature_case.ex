defmodule ContractWeb.FeatureCase do
  @moduledoc """
  ExUnit case template for Wallaby browser tests.

  Sets up the Ecto SQL sandbox in shared (non-async) mode, then starts a
  Wallaby session pre-loaded with the sandbox metadata so the real browser
  shares the same checkout as the test process. The metadata flows through
  the `user-agent` header via the `Phoenix.Ecto.SQL.Sandbox` plug wired
  into `ContractWeb.Endpoint` under `compile_env :sql_sandbox` (see
  `config/test.exs`).

  Tests using this case should set `@moduletag :browser`. The default
  `mix test` run excludes `:browser` (see `test/test_helper.exs`); run
  `mix test --include browser` to drive the suite through Chromium.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Contract.PersonaFactory
      import ContractWeb.FeatureCase

      alias Contract.PersonaFactory
      alias Wallaby.Query
    end
  end

  setup tags do
    # `setup_sandbox/1` opens a sandbox owner pinned to the current test
    # pid; passing `async: false` (the default for browser tests) makes it
    # shared so the Wallaby HTTP requests can check out the same connection.
    Contract.DataCase.setup_sandbox(tags)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Contract.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    {:ok, session: session}
  end
end
