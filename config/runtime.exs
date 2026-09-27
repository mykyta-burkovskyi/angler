import Config

# config/runtime.exs is executed for all environments, including during releases.
# Everything deployment-specific is read from environment variables here; see
# .env.example for the full list.

env = fn name, default ->
  System.get_env(name) |> then(&if(&1 in [nil, ""], do: default, else: &1))
end

int_env = fn name, default ->
  with value when is_binary(value) <- env.(name, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> raise "#{name} must be a whole number, got: #{inspect(value)}"
    end
  end
end

bool_env = fn name, default ->
  value = env.(name, nil)
  normalized = value && value |> String.trim() |> String.downcase()

  cond do
    is_nil(value) -> default
    normalized in ~w(1 true yes on) -> true
    normalized in ~w(0 false no off) -> false
    true -> raise "#{name} must be true or false (or 1/0, yes/no, on/off), got: #{inspect(value)}"
  end
end

# A full http(s) URL. A bare host name such as "angler.example.com" would parse
# as a URL without a host and break the dashboard's origin check.
url_env = fn name, default ->
  with url when is_binary(url) <- env.(name, default) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ~w(http https) and host not in [nil, ""] ->
        url

      _ ->
        raise "#{name} must be a full URL such as https://angler.example.com, got: #{inspect(url)}"
    end
  end
end

public_url = url_env.("PUBLIC_URL", nil)

if System.get_env("PHX_SERVER") do
  config :angler, AnglerWeb.Endpoint, server: true
end

config :angler, AnglerWeb.Endpoint, http: [port: int_env.("PORT", 4000)]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :angler, AnglerWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/angler_web/router\.ex$"E,
        ~r"lib/angler_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

## Telegram, media tools and pipeline (dev and prod; test is configured in test.exs)

if config_env() != :test do
  token = env.("TELEGRAM_BOT_TOKEN", nil)

  if config_env() == :prod and is_nil(token) do
    raise """
    environment variable TELEGRAM_BOT_TOKEN is missing.
    Create a bot with @BotFather and put its token into .env
    """
  end

  webhook_url =
    url_env.(
      "TELEGRAM_WEBHOOK_URL",
      public_url && String.trim_trailing(public_url, "/") <> "/telegram/webhook"
    )

  default_mode =
    cond do
      is_nil(token) -> "disabled"
      webhook_url -> "webhook"
      true -> "polling"
    end

  mode =
    case env.("TELEGRAM_MODE", default_mode) do
      "webhook" -> :webhook
      "polling" -> :polling
      "disabled" -> :disabled
      other -> raise "TELEGRAM_MODE must be webhook, polling or disabled, got: #{inspect(other)}"
    end

  if mode == :webhook and is_nil(webhook_url) do
    raise "TELEGRAM_MODE=webhook requires PUBLIC_URL (or TELEGRAM_WEBHOOK_URL) to be set"
  end

  api_base_url = url_env.("TELEGRAM_API_BASE_URL", "https://api.telegram.org")
  local_mode = bool_env.("TELEGRAM_LOCAL_MODE", false)
  cloud_api? = String.downcase(URI.parse(api_base_url).host) == "api.telegram.org"

  # Both would otherwise only show up later, as a failed setWebhook or as every
  # upload failing with a Telegram error.
  if local_mode and cloud_api? do
    raise """
    TELEGRAM_LOCAL_MODE=true sends videos as local file paths, which only a local
    Bot API server can read, but TELEGRAM_API_BASE_URL is Telegram's cloud API
    (#{api_base_url}). Set TELEGRAM_API_BASE_URL=http://telegram-bot-api:8081
    (README: "Local Bot API server"), or remove TELEGRAM_LOCAL_MODE.
    """
  end

  if mode == :webhook and cloud_api? and URI.parse(webhook_url).scheme != "https" do
    raise """
    Telegram's cloud API only delivers webhooks to https:// URLs, got: #{webhook_url}
    Use the https:// address of your proxy or tunnel as PUBLIC_URL, set
    TELEGRAM_MODE=polling, or set up the local Bot API server (TELEGRAM_API_BASE_URL).
    """
  end

  # Telegram allows 1-256 characters from A-Z, a-z, 0-9, _ and -. Derive a stable
  # secret from the token when none is given, so restarts keep the same webhook.
  webhook_secret =
    env.("TELEGRAM_WEBHOOK_SECRET", nil) ||
      (token &&
         :crypto.hash(:sha256, "angler-webhook:" <> token)
         |> Base.url_encode64(padding: false))

  config :angler, Angler.Telegram,
    token: token,
    mode: mode,
    api_base_url: api_base_url,
    local_mode: local_mode,
    webhook_url: webhook_url,
    webhook_secret: webhook_secret,
    max_connections: int_env.("TELEGRAM_WEBHOOK_MAX_CONNECTIONS", 40)

  config :angler, Angler.Media,
    data_dir: env.("DATA_DIR", Path.expand("../data", __DIR__)),
    ytdlp_path: env.("YTDLP_PATH", "yt-dlp"),
    ffmpeg_path: env.("FFMPEG_PATH", "ffmpeg"),
    ffprobe_path: env.("FFPROBE_PATH", "ffprobe"),
    cookies_file: env.("YTDLP_COOKIES_FILE", nil),
    # "nightly" or "stable": keep a self-updating copy of yt-dlp under DATA_DIR/bin
    ytdlp_update_channel: env.("YTDLP_UPDATE_CHANNEL", nil),
    # Let yt-dlp reach loopback, LAN and other private addresses (off: links can't
    # be used to fetch from the local network or the compose services).
    allow_private_networks: bool_env.("ALLOW_PRIVATE_NETWORK_DOWNLOADS", false)

  config :angler, Angler.Pipeline,
    enabled: bool_env.("PIPELINE_ENABLED", true),
    download_concurrency: int_env.("DOWNLOAD_CONCURRENCY", 2),
    upload_concurrency: int_env.("UPLOAD_CONCURRENCY", 2),
    max_attempts: int_env.("MAX_ATTEMPTS", 3)
end

if config_env() == :prod do
  database_url =
    env.("DATABASE_URL", nil) ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if bool_env.("ECTO_IPV6", false), do: [:inet6], else: []

  config :angler, Angler.Repo,
    url: database_url,
    pool_size: int_env.("POOL_SIZE", 10),
    socket_options: maybe_ipv6

  secret_key_base =
    env.("SECRET_KEY_BASE", nil) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: openssl rand -base64 48
      """

  dashboard_password =
    env.("DASHBOARD_PASSWORD", nil) ||
      raise """
      environment variable DASHBOARD_PASSWORD is missing.
      The dashboard is protected with HTTP basic auth (user: DASHBOARD_USERNAME, default "admin").
      """

  config :angler, AnglerWeb.DashboardAuth,
    username: env.("DASHBOARD_USERNAME", "admin"),
    password: dashboard_password

  %URI{host: host, scheme: scheme, port: port} = URI.parse(public_url || "http://localhost:4000")

  config :angler, AnglerWeb.OriginCheck,
    hosts: [
      host
      | String.split(env.("ALLOWED_ORIGINS", ""), ",", trim: true) |> Enum.map(&String.trim/1)
    ]

  config :angler, AnglerWeb.Endpoint,
    url: [host: host, port: port, scheme: scheme],
    http: [
      # Bind on all IPv4 and IPv6 interfaces inside the container.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
