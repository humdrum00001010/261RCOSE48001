defmodule Ecrits.Repo do
  @moduledoc """
  Local SQLite repository for the ecrits app store.

  This repo intentionally stays separate from `Ecrits.LegacyRepo`, which is a
  retired compatibility boundary for the old hosted SQL surface.
  """

  use Ecto.Repo,
    otp_app: :ecrits,
    adapter: Ecto.Adapters.SQLite3

  @default_directory "~/.ecrits"
  @default_database "ecrits.sqlite3"

  @impl true
  def init(_type, config) do
    database =
      config
      |> Keyword.get(:database, default_database_path())
      |> normalize_database_path()

    database
    |> Path.dirname()
    |> File.mkdir_p!()

    {:ok, Keyword.put(config, :database, database)}
  end

  @spec default_database_path() :: Path.t()
  def default_database_path do
    @default_directory
    |> Path.join(@default_database)
    |> Path.expand()
  end

  defp normalize_database_path(database) when is_binary(database), do: Path.expand(database)
end
