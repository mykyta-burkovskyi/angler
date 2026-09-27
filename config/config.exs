# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :angler,
  ecto_repos: [Angler.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Telegram Bot API (see Angler.Telegram.Config; secrets are read in runtime.exs)
config :angler, Angler.Telegram,
  api_base_url: "https://api.telegram.org",
  local_mode: false,
  mode: :disabled,
  max_connections: 40

# External tools and where media is stored while processing / kept afterwards
config :angler, Angler.Media,
  data_dir: Path.expand("../data", __DIR__),
  ytdlp_path: "yt-dlp",
  ffmpeg_path: "ffmpeg",
  ffprobe_path: "ffprobe",
  cookies_file: nil,
  ytdlp_update_channel: nil,
  # yt-dlp may not reach loopback/private/link-local addresses or the compose
  # services unless enabled (ALLOW_PRIVATE_NETWORK_DOWNLOADS)
  allow_private_networks: false

# Broadway pipeline (see Angler.Pipeline)
config :angler, Angler.Pipeline,
  enabled: true,
  download_concurrency: 2,
  upload_concurrency: 2,
  max_attempts: 3

# Configure the endpoint
config :angler, AnglerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AnglerWeb.ErrorHTML, json: AnglerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Angler.PubSub,
  live_view: [signing_salt: "NTBlLIdS"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  angler: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  angler: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
