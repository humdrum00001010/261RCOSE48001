defmodule ContractWeb.DocumentScope do
  @moduledoc """
  LiveView on_mount hook for document-first product routes.

  Authentication assigns `current_scope`; this hook only threads
  session-provided persona permissions and the current route document id.
  Matter is no longer part of the product route scope.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Contract.Context

  def on_mount(:assign_scope, params, session, socket) do
    document_id = route_document_id(params)

    socket =
      socket
      |> assign_perms(session)
      |> assign(:current_document_id, document_id)

    {:cont, socket}
  end

  defp route_document_id(%{"document_id" => id}) when is_binary(id) and id != "", do: id
  defp route_document_id(_params), do: nil

  defp assign_perms(%{assigns: %{current_scope: %Context{} = scope}} = socket, session) do
    case session_perms(session) do
      nil -> socket
      perms -> assign(socket, :current_scope, %Context{scope | perms: perms})
    end
  end

  defp assign_perms(socket, _session), do: socket

  defp session_perms(session) when is_map(session) do
    case Map.get(session, "user_perms") || Map.get(session, :user_perms) do
      perms when is_list(perms) -> perms
      _ -> nil
    end
  end

  defp session_perms(_), do: nil
end
