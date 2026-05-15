defmodule Contract.Accounts.UserNotifier do
  @moduledoc """
  Builds and dispatches gen.auth transactional emails.

  Public `deliver_*` functions enqueue an Oban job on the `:mailer`
  queue rather than calling `Contract.Mailer.deliver/1` directly.
  Worksmobile SMTP on port 465 takes 2-5 s per send; doing that
  synchronously inside a LiveView `handle_event/3` blocks the socket
  for the duration of the SMTP handshake. The Oban indirection lets
  the LV return immediately and the worker handles the actual send.

  Each public `deliver_*` has a `perform_*` sibling invoked by
  `Contract.Workers.MailerJob`. The `perform_*` function re-fetches
  the user by id (Oban args are JSON — no struct round-trip) and
  calls `Contract.Mailer.deliver/1`.

  Return shape of `deliver_*` is `{:ok, %Oban.Job{}}` on enqueue.
  Tests that need to assert on the delivered email must drain the
  queue via `Oban.drain_queue(queue: :mailer)` and then read the
  Swoosh test inbox (`Swoosh.TestAssertions.assert_email_sent/1`).
  See `Contract.AccountsFixtures.extract_user_token/1` for the
  helper that wraps this drain.
  """
  import Swoosh.Email

  alias Contract.Mailer
  alias Contract.Accounts
  alias Contract.Accounts.User
  alias Contract.Workers.MailerJob

  # ---------------------------------------------------------------------------
  # Public API — enqueue an Oban job on the :mailer queue.
  # ---------------------------------------------------------------------------

  @doc """
  Enqueue an "update email instructions" email. Returns `{:ok, %Oban.Job{}}`.
  """
  def deliver_update_email_instructions(%User{} = user, url) when is_binary(url) do
    enqueue("update_email_instructions", %{"user_id" => user.id, "url" => url})
  end

  @doc """
  Enqueue a login-instructions email. For unconfirmed users this
  dispatches to the confirmation-instructions path; for confirmed
  users it dispatches to the magic-link path. The branching happens
  inside the worker so the LV's request stays a single enqueue.
  """
  def deliver_login_instructions(%User{} = user, url) when is_binary(url) do
    enqueue("login_instructions", %{"user_id" => user.id, "url" => url})
  end

  defp enqueue(kind, args) do
    %{"kind" => kind, "args" => args}
    |> MailerJob.new()
    |> Oban.insert()
  end

  # ---------------------------------------------------------------------------
  # Worker entry points — invoked by Contract.Workers.MailerJob.
  # Each takes a JSON-decoded args map, re-fetches the user, builds the
  # email, and calls Mailer.deliver/1.
  # ---------------------------------------------------------------------------

  @doc false
  def perform_update_email_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "Update email instructions", update_email_body(user, url))
  end

  @doc false
  def perform_login_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)

    case user do
      %User{confirmed_at: nil} ->
        perform_confirmation_instructions(%{"user_id" => user_id, "url" => url})

      _ ->
        perform_magic_link_instructions(%{"user_id" => user_id, "url" => url})
    end
  end

  @doc false
  def perform_confirmation_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "Confirmation instructions", confirmation_body(user, url))
  end

  @doc false
  def perform_magic_link_instructions(%{"user_id" => user_id, "url" => url}) do
    user = Accounts.get_user!(user_id)
    deliver_now(user.email, "Log in instructions", magic_link_body(user, url))
  end

  # ---------------------------------------------------------------------------
  # Internals — actual SMTP send + body templates.
  # ---------------------------------------------------------------------------

  defp deliver_now(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp update_email_body(user, url) do
    """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """
  end

  defp magic_link_body(user, url) do
    """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """
  end

  defp confirmation_body(user, url) do
    """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """
  end
end
