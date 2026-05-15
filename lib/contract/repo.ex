defmodule Contract.Repo do
  use Ecto.Repo,
    otp_app: :contract,
    adapter: Ecto.Adapters.Postgres
end
