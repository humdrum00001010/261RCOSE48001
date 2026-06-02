defmodule Ecrits.Mailer do
  use Swoosh.Mailer, otp_app: :ecrits

  @doc """
  Default From tuple, sourced from application env at runtime.

  Set in `config/runtime.exs` as:

      config :ecrits, :mail_from, {"Ecrits", "ereignis@korea.ac.kr"}

  In dev/test where the env var may not be set, returns a placeholder
  so the generated `UserNotifier` keeps working under
  `Swoosh.Adapters.Local` and `Swoosh.Adapters.Test`.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    Application.get_env(:ecrits, :mail_from, {"Ecrits", "no-reply@example.com"})
  end
end
