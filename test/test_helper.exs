ExUnit.start(exclude: [:live_smtp, :live, :live_openai, :live_law_mcp])

# Engine and other pure-mechanics tests run without the database. We only
# switch the sandbox into :manual mode when the Repo actually started up.
case Process.whereis(Contract.Repo) do
  nil ->
    :ok

  _pid ->
    Ecto.Adapters.SQL.Sandbox.mode(Contract.Repo, :manual)
end

# Mox definitions for IO drivers. The test config swaps in
# `Contract.IO.OpenAIMock` for the OpenAI driver.
Mox.defmock(Contract.IO.OpenAIMock, for: Contract.IO.OpenAI.Behaviour)
Mox.set_mox_global()
