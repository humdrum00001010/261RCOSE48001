defmodule Ecrits.RepoTest do
  use ExUnit.Case, async: true

  test "defaults to an ecrits sqlite database under the user home" do
    assert Ecrits.Repo.default_database_path() == Path.expand("~/.ecrits/ecrits.sqlite3")
  end

  test "init expands the configured database path and creates its parent directory" do
    database =
      System.tmp_dir!()
      |> Path.join("ecrits-repo-test-#{System.unique_integer([:positive])}")
      |> Path.join("nested/ecrits.sqlite3")

    on_exit(fn -> File.rm_rf!(Path.dirname(Path.dirname(database))) end)

    assert {:ok, config} = Ecrits.Repo.init(:supervisor, database: database)
    assert config[:database] == Path.expand(database)
    assert File.dir?(Path.dirname(database))
  end

  test "application startup creates and migrates the configured sqlite database" do
    assert Ecrits.Repo.config()[:priv] == "priv/ecrits_repo"
    assert %{rows: [[_user_version]]} = Ecrits.Repo.query!("PRAGMA user_version", [])

    assert %{rows: [["ecrits_metadata"]]} =
             Ecrits.Repo.query!(
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ecrits_metadata'",
               []
             )

    assert %{rows: migration_rows} =
             Ecrits.Repo.query!("SELECT version FROM schema_migrations", [])

    assert [20_260_602_000_000] in migration_rows
    assert Process.whereis(Ecrits.Loader)
  end
end
