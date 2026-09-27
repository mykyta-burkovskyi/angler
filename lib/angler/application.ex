defmodule Angler.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AnglerWeb.Telemetry,
      Angler.Repo,
      # Run migrations on boot inside releases (the Docker image); `mix` handles them otherwise.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:angler, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Angler.PubSub},
      {Finch, name: Angler.Finch},
      {Task.Supervisor, name: Angler.TaskSupervisor},
      # Keeps a self-updating yt-dlp copy when YTDLP_UPDATE_CHANNEL is set.
      Angler.Media.Updater,
      {Angler.Telegram.RateLimiter,
       Application.get_env(:angler, Angler.Telegram.RateLimiter, [])},
      Angler.Storage.Janitor,
      Angler.Pipeline,
      AnglerWeb.Endpoint,
      # Registers the webhook / starts polling once the endpoint accepts requests.
      Angler.Telegram.Receiver
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Angler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AnglerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
