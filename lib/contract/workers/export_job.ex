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
        "format"      => "pdf" | "docx" | "html" | "hwpx" | ...,
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
  alias Contract.Export.Renderer

  @pubsub Contract.PubSub

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id, "format" => format} = args}) do
    requester_id = Map.get(args, "requester_id")
    format_atom = parse_format(format)
    export_id = Map.get(args, "export_id") || Ecto.UUID.generate()

    topic = "document:#{doc_id}"

    case do_export(doc_id, format_atom, export_id, requester_id) do
      {:ok, %Export{} = export} ->
        Phoenix.PubSub.broadcast(@pubsub, topic, {:export_ready, export})
        :ok

      {:error, reason} = err ->
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
    with {:ok, state} <- Contract.Store.load(doc_id),
         {:ok, body, content_type} <- Renderer.render(state, format),
         key = "exports/#{export_id}.#{extension(format)}",
         {:ok, _} <- r2_driver().put(key, body, content_type: content_type),
         {:ok, url} <- r2_driver().presigned_url(key, expires_in: 7 * 24 * 3600) do
      {:ok,
       %Export{
         id: export_id,
         document_id: doc_id,
         format: format,
         key: key,
         url: url,
         requester_id: requester_id
       }}
    end
  end

  defp parse_format(fmt) when is_atom(fmt), do: fmt

  defp parse_format(fmt) when is_binary(fmt) do
    try do
      String.to_existing_atom(fmt)
    rescue
      ArgumentError -> String.to_atom(fmt)
    end
  end

  defp extension(:pdf), do: "pdf"
  defp extension(:docx), do: "docx"
  defp extension(:html), do: "html"
  defp extension(:md), do: "md"
  defp extension(:markdown), do: "md"
  defp extension(:hwpx), do: "hwpx"
  defp extension(other), do: to_string(other)

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end
end
