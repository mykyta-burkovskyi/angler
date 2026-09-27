defmodule Angler.Telegram.Config do
  @moduledoc """
  Telegram configuration, set in `config/runtime.exs` under `config :angler, Angler.Telegram`:

    * `:token` - bot token from @BotFather
    * `:api_base_url` - `https://api.telegram.org` or a local Bot API server, e.g. `http://telegram-bot-api:8081`
    * `:local_mode` - the local Bot API server runs with `--local` (2000 MB uploads, local file paths)
    * `:mode` - `:webhook`, `:polling` or `:disabled` (no updates are received, e.g. in tests)
    * `:webhook_url` - public HTTPS URL Telegram posts updates to (webhook mode)
    * `:webhook_secret` - value Telegram sends in `X-Telegram-Bot-Api-Secret-Token`
    * `:max_connections` - `max_connections` passed to `setWebhook`
    * `:req_options` - extra `Req` options (tests use `plug: {Req.Test, Angler.Telegram}`)
  """

  defp config, do: Application.get_env(:angler, Angler.Telegram, [])

  def token, do: Keyword.get(config(), :token)
  def api_base_url, do: Keyword.get(config(), :api_base_url, "https://api.telegram.org")
  def local_mode?, do: Keyword.get(config(), :local_mode, false)
  def mode, do: Keyword.get(config(), :mode, :disabled)
  def webhook_url, do: Keyword.get(config(), :webhook_url)
  def webhook_secret, do: Keyword.get(config(), :webhook_secret)
  def max_connections, do: Keyword.get(config(), :max_connections, 40)
  def req_options, do: Keyword.get(config(), :req_options, [])
end
