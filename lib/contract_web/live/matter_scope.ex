defmodule ContractWeb.MatterScope do
  @moduledoc """
  LiveView `on_mount` hook that reads `:matter_id` from the route params and
  stuffs the resolved matter into `socket.assigns.current_scope.matter`.

  Until `Contract.Matters` lands (Wave 3C2 roadmap), the resolved matter is
  a minimal stub map: `%{id: matter_id, name: "Matter " <> short}`. The
  `Contract.Context` struct already accepts an opaque `:matter` field, so
  shells using this hook (StudioLive) don't depend on the eventual schema.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Contract.Context

  @doc """
  on_mount callback: attaches matter (if matter_id present) onto
  `current_scope`.
  """
  def on_mount(:assign_scope, params, _session, socket) do
    matter_id =
      case params do
        %{"matter_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    socket = assign_matter(socket, matter_id)
    {:cont, socket}
  end

  defp assign_matter(socket, nil), do: socket

  defp assign_matter(%{assigns: %{current_scope: %Context{} = scope}} = socket, matter_id) do
    matter = load_matter(matter_id)
    assign(socket, :current_scope, %Context{scope | matter: matter})
  end

  defp assign_matter(socket, _matter_id), do: socket

  # Stub matter loader. When Contract.Matters lands, this becomes
  # `Contract.Matters.get_for_scope(scope, matter_id)`.
  defp load_matter(matter_id) when is_binary(matter_id) do
    %{id: matter_id, name: "Matter " <> String.slice(matter_id, 0, 8)}
  end
end
