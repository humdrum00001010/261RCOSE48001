defmodule Ecrits.Loader do
  @moduledoc """
  Forces the local ecrits SQLite database to open during application startup.
  """

  use GenServer

  alias Ecrits.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    migrated_versions = migrate!()
    _ = Repo.query!("PRAGMA user_version", [])

    {:ok,
     %{
       database: Repo.config()[:database],
       migrated_versions: migrated_versions
     }}
  end

  def migrate! do
    Ecto.Migrator.run(Repo, :up, all: true)
  end
end
