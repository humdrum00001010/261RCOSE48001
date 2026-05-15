defmodule ContractWeb.Router do
  use ContractWeb, :router

  import ContractWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContractWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ContractWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Contract Studio LiveView routes (SPEC.md §4).
  # Browser product flow is LiveView-only — no `/api` for user actions.
  scope "/", ContractWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :studio,
      on_mount: [{ContractWeb.UserAuth, :require_authenticated}] do
      live "/studio", StudioLive
      live "/matters/:matter_id/studio", StudioLive
      live "/matters/:matter_id/documents/:document_id", StudioLive
    end
  end

  # External ingress — Gateway track (separate worktree) will implement these
  # properly. Until then they return 501 Not Implemented.
  scope "/mcp" do
    pipe_through :api
    forward "/", ContractWeb.NotImplementedPlug, label: "/mcp"
  end

  scope "/slack" do
    pipe_through :api
    post "/events", ContractWeb.NotImplementedPlug, label: "/slack/events"
    post "/actions", ContractWeb.NotImplementedPlug, label: "/slack/actions"
    post "/commands", ContractWeb.NotImplementedPlug, label: "/slack/commands"
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:contract, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContractWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ContractWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ContractWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ContractWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ContractWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
