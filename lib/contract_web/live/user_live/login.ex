defmodule ContractWeb.UserLive.Login do
  use ContractWeb, :live_view

  alias Contract.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="split">
      <.auth_split>
        <:aside>
          <h2 class="text-2xl font-semibold tracking-tight leading-snug">
            Drafting that asks before it edits.
          </h2>
          <p class="text-base-content/70 mt-3 leading-relaxed">
            Pick up where you left off. The agent's pending questions, your matter timeline, and every uncommitted edit are right where you parked them.
          </p>
          <ul class="text-sm text-base-content/60 space-y-2 mt-6">
            <li class="flex gap-2"><.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" /> 법제처 citations verified before they hit the page.</li>
            <li class="flex gap-2"><.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" /> No silent rewrites. Every change is a row.</li>
          </ul>
        </:aside>

        <:form>
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight">
              <%= if @current_scope do %>
                Re-authenticate
              <% else %>
                Log in
              <% end %>
            </h1>
            <p class="text-sm text-base-content/60">
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                New here?
                <.link navigate={~p"/users/register"} class="font-medium text-primary hover:underline" phx-no-format>Sign up</.link>
                — Contract Studio is invite-only for the closed beta.
              <% end %>
            </p>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="size-5 shrink-0" />
            <div>
              <p class="font-medium">Local mail adapter is active.</p>
              <p class="text-sm">
                Magic links land in <.link href="/dev/mailbox" class="underline">the dev mailbox</.link>, not real email.
              </p>
            </div>
          </div>

          <div class="mt-6 space-y-6">
            <.form
              :let={f}
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
              class="space-y-3"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <.button class="btn btn-primary w-full">
                Log in with email <span aria-hidden="true">→</span>
              </.button>
              <p class="text-xs text-base-content/50">
                We'll send a one-time link. No password required.
              </p>
            </.form>

            <div class="divider text-xs text-base-content/40">or use a password</div>

            <.form
              :let={f}
              for={@form}
              id="login_form_password"
              action={~p"/users/log-in"}
              phx-submit="submit_password"
              phx-trigger-action={@trigger_submit}
              class="space-y-3"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="current-password"
                spellcheck="false"
              />
              <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
                Log in and stay logged in <span aria-hidden="true">→</span>
              </.button>
              <.button class="btn btn-ghost w-full">
                Log in only this time
              </.button>
            </.form>
          </div>

          <p class="text-xs text-base-content/50 mt-8 text-center">
            Trouble signing in?
            <a href="mailto:support@contractstudio.example" class="underline hover:text-base-content">
              Email support
            </a>
          </p>
        </:form>
      </.auth_split>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:contract, Contract.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
