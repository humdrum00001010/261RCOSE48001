defmodule ContractWeb.MatterScope do
  @moduledoc """
  LiveView `on_mount` hook that:

    1. Reads `:matter_id` from the route params and stuffs the resolved
       matter into `socket.assigns.current_scope.matter`.
    2. Seeds `current_scope.perms` from the session (the persona sign-in
       flow in `ContractWeb.TestAuthController` writes `:user_perms` into
       the session, and we thread that here so components can gate on
       perms like `:write` / `:agent_run` / `:type_change`).

  Until `Contract.Matters` lands (Wave 3C2 roadmap), the resolved matter is
  a minimal stub map: `%{id: matter_id, name: "Matter " <> short}`. The
  `Contract.Context` struct already accepts an opaque `:matter` field, so
  shells using this hook (StudioLive) don't depend on the eventual schema.

  Perms seeding is unconditional: if the session has `:user_perms`, the
  scope gets them; if not, `current_scope.perms` stays at whatever
  upstream (`Contract.Context.for_user/1`) set it to (currently `nil`).
  Components that gate on perms must defensively treat `nil` as "no
  perms" (e.g. `Canvas.Empty`'s `can_write?(_), do: false`).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Contract.Context

  @doc """
  on_mount callback: seeds perms from the session and attaches matter
  (if matter_id present) onto `current_scope`.
  """
  def on_mount(:assign_scope, params, session, socket) do
    matter_id =
      case params do
        %{"matter_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    socket =
      socket
      |> assign_perms(session)
      |> assign_matter(matter_id)

    {:cont, socket}
  end

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
