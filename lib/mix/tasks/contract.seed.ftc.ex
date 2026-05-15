defmodule Mix.Tasks.Contract.Seed.Ftc do
  @moduledoc """
  Enqueue FTC standard-contract template seed jobs.

  Reads `priv/seeds/ftc_templates.exs` and enqueues one
  `Contract.Workers.FtcSeedJob` per entry. The worker is idempotent
  (`check_not_already_seeded/3`), so running this task twice is a
  no-op for already-seeded `type_key`s.

  Live seeding makes real network calls to ftc.go.kr **and** to the
  Upstage Document Parse API. Burn quota deliberately, not in CI.

  ## Usage

      # enqueue + let Oban execute on the :system queue
      mix contract.seed.ftc

      # enqueue and immediately drain the :system queue inline
      mix contract.seed.ftc --drain
  """
  use Mix.Task

  @shortdoc "Enqueue FTC template seed jobs"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    drain? = "--drain" in argv

    manifest_path = Path.expand("priv/seeds/ftc_templates.exs", File.cwd!())

    templates =
      case File.exists?(manifest_path) do
        true ->
          {value, _binding} = Code.eval_file(manifest_path)
          value

        false ->
          Mix.raise("missing seed manifest: #{manifest_path}")
      end

    case templates do
      list when is_list(list) ->
        Enum.each(list, &enqueue/1)
        Mix.shell().info("[seed.ftc] enqueued #{length(list)} FTC seed jobs")

      _ ->
        Mix.raise("seed manifest did not return a list of maps: #{inspect(templates)}")
    end

    if drain? do
      Mix.shell().info("[seed.ftc] draining :system queue inline...")
      _ = Oban.drain_queue(queue: :system, with_safety: true)
      Mix.shell().info("[seed.ftc] drain complete")
    end

    :ok
  end

  defp enqueue(%{type_key: type_key, source_url: url, title: title}) do
    %{"type_key" => type_key, "source_url" => url, "title" => title}
    |> Contract.Workers.FtcSeedJob.new()
    |> Oban.insert!()
  end
end
