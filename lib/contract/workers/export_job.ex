defmodule Contract.Workers.ExportJob do
  @moduledoc """
  Asynchronous export worker.

  Triggered from `Contract.Runtime.apply/2` when a
  `:request_export` Action arrives. Loads the document state, renders to
  the requested format via `Contract.Export.Renderer.render/3`, uploads
  the bytes to R2 under `exports/<export_id>.<ext>`, fetches a
  presigned URL, and broadcasts `{:export_ready, %Contract.Export{}}`
  on the document's PubSub topic (`document:<doc_id>`).

  ## Args

      %{
        "document_id" => uuid,
        "format"      => "pdf" | "docx" | "hwpx" | "markdown" | "lawyer_packet",
        "requester_id"=> uuid | nil       # optional
      }

  ## Failure handling

    * If `Contract.Store.load/1` fails → returns the error; Oban retries
      per `max_attempts`.
    * If rendering fails → broadcasts `{:export_failed, export_id,
      reason}` so the LV can surface a toast, and returns `{:error, …}`
      to mark the job failed.
    * If R2 upload fails → same fail-broadcast path.
  """
  use Oban.Worker, queue: :export, max_attempts: 3

  alias Contract.Export
  alias Contract.Exports
  alias Contract.Providers

  @pubsub Contract.PubSub
  @supported_formats [:pdf, :docx, :hwpx, :markdown, :lawyer_packet]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id, "format" => format} = args}) do
    requester_id = Map.get(args, "requester_id")
    export_id = Map.get(args, "export_id") || Ecto.UUID.generate()
    topic = "document:#{doc_id}"

    with {:ok, format_atom} <- parse_format(format) do
      broadcast_status(topic, export_id, doc_id, format_atom, :running, 10, nil)

      case do_export(doc_id, format_atom, export_id, requester_id) do
        {:ok, %Export{} = export} ->
          broadcast_status(
            topic,
            export_id,
            doc_id,
            format_atom,
            :ready,
            100,
            export.download_url
          )

          Phoenix.PubSub.broadcast(@pubsub, topic, {:export_ready, export})
          :ok

        {:error, reason} = err ->
          _ = Exports.mark_failed(export_id, reason)
          broadcast_status(topic, export_id, doc_id, format_atom, :failed, 100, nil)
          Phoenix.PubSub.broadcast(@pubsub, topic, {:export_failed, export_id, reason})
          err
      end
    else
      {:error, reason} = err ->
        _ = Exports.mark_failed(export_id, reason)
        Phoenix.PubSub.broadcast(@pubsub, topic, {:export_failed, export_id, reason})
        err
    end
  end

  def perform(%Oban.Job{args: args}),
    do: {:error, {:bad_export_args, args}}

  # --------------------------------------------------------------------
  # internals
  # --------------------------------------------------------------------

  defp do_export(doc_id, format, export_id, requester_id) do
    with {:ok, _export} <- Exports.mark_running(export_id),
         {:ok, state} <- Contract.Store.load(doc_id),
         {:ok, body, content_type} <- Providers.render_export(nil, state, format),
         key = "exports/#{export_id}.#{extension(format)}",
         {:ok, _} <- r2_driver().put(key, body, content_type: content_type),
         download_url = "/exports/#{export_id}/download",
         {:ok, export} <-
           Exports.mark_ready(export_id, %{
             key: key,
             download_url: download_url,
             content_type: content_type,
             byte_size: byte_size(body)
           }) do
      {:ok, %{export | requester_id: requester_id, url: download_url}}
    end
  end

  defp parse_format(fmt) when fmt in @supported_formats, do: {:ok, fmt}

  defp parse_format(fmt) when is_atom(fmt), do: {:error, {:unsupported_format, fmt}}

  defp parse_format(fmt) when is_binary(fmt) do
    case fmt do
      "pdf" -> {:ok, :pdf}
      "docx" -> {:ok, :docx}
      "hwpx" -> {:ok, :hwpx}
      "markdown" -> {:ok, :markdown}
      "md" -> {:ok, :markdown}
      "lawyer_packet" -> {:ok, :lawyer_packet}
      _ -> {:error, {:unsupported_format, fmt}}
    end
  end

  defp parse_format(fmt), do: {:error, {:unsupported_format, fmt}}

  defp extension(:pdf), do: "pdf"
  defp extension(:docx), do: "docx"
  defp extension(:markdown), do: "md"
  defp extension(:lawyer_packet), do: "md"
  defp extension(:hwpx), do: "hwpx"

  defp broadcast_status(topic, export_id, doc_id, format, status, progress, download_url) do
    Phoenix.PubSub.broadcast(@pubsub, topic, {
      :export_status,
      %{
        id: export_id,
        document_id: doc_id,
        format: format,
        status: status,
        progress: progress,
        download_url: download_url
      }
    })
  end

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end
end
