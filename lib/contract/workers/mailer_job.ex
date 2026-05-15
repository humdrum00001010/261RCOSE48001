defmodule Contract.Workers.MailerJob do
  @moduledoc """
  Background worker that delivers transactional emails enqueued by the
  `Contract.Accounts.UserNotifier` public `deliver_*` functions.

  Why: Worksmobile SMTP over implicit TLS (port 465) takes 2-5 seconds per
  send. Doing that synchronously inside a LiveView `handle_event/3` makes
  the form submit feel broken — the user sees the spinner spin for
  multiple seconds and may double-submit or assume the page crashed.
  Moving the deliver into an Oban job lets `handle_event/3` return
  immediately while the worker pool drains the SMTP send in the
  background.

  Args shape:

      %{
        "kind" => "<notifier-suffix>",
        "args" => %{...kind-specific payload...}
      }

  The worker looks up `Contract.Accounts.UserNotifier.perform_<kind>/1`
  via `apply/3` and hands it the args map. Each `perform_*` function is
  responsible for re-fetching any DB rows by id (Oban args are JSON, so
  we never round-trip a struct) and calling `Contract.Mailer.deliver/1`.

  Tests run with `config :contract, Oban, testing: :manual` (set in
  `config/test.exs`), so jobs are inserted but NOT auto-executed. Tests
  that need to assert on the delivered email must drain the queue via
  `Oban.drain_queue(queue: :mailer)` and then check the Swoosh test
  inbox via `Swoosh.TestAssertions.assert_email_sent/1`.
  """
  use Oban.Worker, queue: :mailer, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "args" => args}}) when is_binary(kind) do
    fun = String.to_existing_atom("perform_" <> kind)
    apply(Contract.Accounts.UserNotifier, fun, [args])
  end
end
