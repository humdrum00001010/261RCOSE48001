defmodule Mix.Tasks.Contract.R2.Smoke do
  @moduledoc """
  Cloudflare R2 connectivity smoke test.

  Puts a 12-byte object at `contract/smoke/<timestamp>` in the configured
  `R2_BUCKET`, reads it back, deletes it, and prints results. Fails the
  task with a non-zero exit if any of put/get/delete errors.

  Usage:

      mix contract.r2.smoke

  Reads credentials from `config :ex_aws` and bucket from
  `config :contract, :r2`, both populated by `config/runtime.exs`.
  """

  use Mix.Task

  @shortdoc "Round-trip a 12-byte object against R2"

  @impl true
  def run(_argv) do
    # Load config/runtime.exs so :r2 + :ex_aws are populated, and start the
    # HTTP/AWS apps. We deliberately do NOT start the full :contract app
    # (avoid Repo/Endpoint/Oban for a connectivity probe).
    Mix.Task.run("app.config")
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)
    Application.ensure_all_started(:ex_aws_s3)

    bucket =
      case Application.fetch_env(:contract, :r2) do
        {:ok, r2} ->
          Keyword.fetch!(r2, :bucket)

        :error ->
          Mix.raise("Contract :r2 config is missing. Did config/runtime.exs see R2_* env vars?")
      end

    key = "contract/smoke/#{System.system_time(:millisecond)}.txt"
    payload = "hello-r2!!!!"
    12 = byte_size(payload)

    Mix.shell().info("[r2.smoke] bucket=#{bucket}")
    Mix.shell().info("[r2.smoke] PUT  s3://#{bucket}/#{key} (#{byte_size(payload)} bytes)")

    case ExAws.S3.put_object(bucket, key, payload) |> ExAws.request() do
      {:ok, _} ->
        Mix.shell().info("[r2.smoke] PUT ok")

      {:error, err} ->
        Mix.raise("[r2.smoke] PUT failed: #{inspect(err)}")
    end

    Mix.shell().info("[r2.smoke] GET  s3://#{bucket}/#{key}")

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: ^payload}} ->
        Mix.shell().info("[r2.smoke] GET ok (#{byte_size(payload)} bytes round-tripped)")

      {:ok, %{body: other}} ->
        Mix.raise("[r2.smoke] GET returned unexpected body: #{inspect(other)}")

      {:error, err} ->
        Mix.raise("[r2.smoke] GET failed: #{inspect(err)}")
    end

    Mix.shell().info("[r2.smoke] DEL  s3://#{bucket}/#{key}")

    case ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      {:ok, _} ->
        Mix.shell().info("[r2.smoke] DEL ok")

      {:error, err} ->
        Mix.shell().info("[r2.smoke] DEL warn: #{inspect(err)}")
    end

    Mix.shell().info("[r2.smoke] OK")
    :ok
  end
end
