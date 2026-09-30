defmodule AnglerWeb.Router do
  use AnglerWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnglerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :dashboard_auth do
    plug AnglerWeb.DashboardAuth
  end

  # Telegram posts updates here; authenticated by the secret token header.
  scope "/telegram", AnglerWeb do
    post "/webhook", TelegramWebhookController, :create
  end

  # Liveness/readiness probe for docker compose (no auth, no session).
  scope "/", AnglerWeb do
    get "/health", HealthController, :show
  end

  scope "/", AnglerWeb do
    pipe_through [:browser, :dashboard_auth]

    get "/media/:id/video", MediaController, :video
    get "/media/:id/thumbnail", MediaController, :thumbnail
    get "/media/:id/items/:index", MediaController, :item
    get "/media/:id/items/:index/thumbnail", MediaController, :item_thumbnail

    live_session :dashboard, on_mount: AnglerWeb.DashboardAuth do
      live "/", EntriesLive, :index
      live "/entries/:id", EntryLive, :show
      live "/settings", SettingsLive, :index
    end
  end

  # BEAM/Phoenix/Ecto metrics, behind the same auth as the dashboard.
  scope "/system" do
    pipe_through [:browser, :dashboard_auth]

    live_dashboard "/",
      metrics: AnglerWeb.Telemetry,
      on_mount: [AnglerWeb.DashboardAuth]
  end
end
