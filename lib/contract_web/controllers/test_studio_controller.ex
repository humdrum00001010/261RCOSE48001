if Application.compile_env(:contract, :test_auth, false) do
  defmodule ContractWeb.TestStudioController do
    @moduledoc """
    Playwright-only Studio browser QA hooks.

    Gated behind `Application.compile_env(:contract, :test_auth, false)`: in
    production the module and router entries are not compiled. The runtime plug
    also checks the flag and every action requires a valid authenticated browser
    session.
    """

    use ContractWeb, :controller

    alias Contract.Accounts

    plug :gate_test_auth

    @doc """
    `POST /test/studio/operation_blocks` synthesizes representative operation
    protocol messages for the currently authenticated Studio browser session.
    """
    def operation_blocks(conn, _params) do
      with {:ok, user} <- authenticated_user(conn) do
        run_id = "qa-" <> Ecto.UUID.generate()
        tool_id = "synthetic-operation"
        operation_id = "tool-#{run_id}-#{tool_id}"

        topic = ContractWeb.DocumentLive.test_operation_topic(user.id)

        Phoenix.PubSub.broadcast(Contract.PubSub, topic, {
          :tool_call_started,
          run_id,
          %{
            id: tool_id,
            tool_name: "Synthetic QA operation",
            input: %{query: "operation block browser QA"}
          }
        })

        Phoenix.PubSub.broadcast(Contract.PubSub, topic, {
          :tool_call_completed,
          run_id,
          tool_id,
          %{
            summary: "Synthetic QA operation completed",
            details: %{
              purpose: "Browser QA expand/collapse accessibility",
              operation_id: operation_id
            }
          }
        })

        json(conn, %{ok: true, operation_ids: [operation_id]})
      else
        :error ->
          conn
          |> put_status(:unauthorized)
          |> json(%{ok: false, error: "unauthenticated"})
      end
    end

    defp authenticated_user(conn) do
      with token when is_binary(token) <- get_session(conn, :user_token),
           {%Contract.Accounts.User{} = user, _inserted_at} <-
             Accounts.get_user_by_session_token(token) do
        {:ok, user}
      else
        _ -> :error
      end
    end

    defp gate_test_auth(conn, _opts) do
      if Application.get_env(:contract, :test_auth, false) do
        conn
      else
        conn |> send_resp(404, "") |> halt()
      end
    end
  end
end
