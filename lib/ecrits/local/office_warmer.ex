defmodule Ecrits.Local.OfficeWarmer do
  @moduledoc """
  Pre-warms LibreOffice at boot so the first office (`.doc/.docx/.pptx/...`)
  document opens fast.

  The first `soffice` launch in a fresh process is slow: it builds the
  `UserInstallation` profile, JITs its shared libraries, and primes the OS file
  cache. Doing that lazily on the first real document open makes the editor feel
  unresponsive. This worker does it once at startup, off the critical path, by
  running a throwaway headless `--terminate_after_init`, so the libreofficex
  `WorkerPool` (already supervised by the libreofficex application) hits a warm
  toolchain when a real render arrives.

  It is best-effort: if `soffice` is missing or warming fails, it logs and
  exits normally — document opens still work (just cold). Disabled in `:test`.
  """

  use Task, restart: :transient

  require Logger

  @mac_soffice "/Applications/LibreOffice.app/Contents/MacOS/soffice"
  @warm_timeout 60_000

  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts \\ []) do
    case soffice_executable() do
      {:ok, soffice} -> warm(soffice)
      :error -> Logger.info("[OfficeWarmer] soffice not found; skipping pre-warm")
    end
  end

  defp warm(soffice) do
    profile_dir =
      Path.join(System.tmp_dir!(), "libreofficex-warm-#{System.unique_integer([:positive])}")

    _ = File.mkdir_p(profile_dir)

    args = [
      "--headless",
      "--nologo",
      "--nofirststartwizard",
      "--nodefault",
      "--nolockcheck",
      "-env:UserInstallation=file://#{URI.encode(profile_dir)}",
      "--terminate_after_init"
    ]

    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd(soffice, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @warm_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        Logger.info(
          "[OfficeWarmer] soffice warmed in #{System.monotonic_time(:millisecond) - started}ms"
        )

      {:ok, {output, status}} ->
        Logger.warning("[OfficeWarmer] soffice warm exited #{status}: #{String.slice(output, 0, 200)}")

      nil ->
        Logger.warning("[OfficeWarmer] soffice warm timed out")
    end

    _ = File.rm_rf(profile_dir)
    :ok
  end

  defp soffice_executable do
    candidates =
      case System.get_env("LIBREOFFICEX_SOFFICE") do
        path when is_binary(path) and path != "" -> [path]
        _ -> [@mac_soffice, "soffice"]
      end

    Enum.find_value(candidates, :error, fn candidate ->
      cond do
        String.contains?(candidate, "/") and File.exists?(candidate) -> {:ok, candidate}
        String.contains?(candidate, "/") -> nil
        path = System.find_executable(candidate) -> {:ok, path}
        true -> nil
      end
    end)
  end
end
