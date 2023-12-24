defmodule Angler.Application do
  use Application

  @impl true
  def start(_type, _args) do
    bot_config = [
      token: Application.fetch_env!(:angler, :token),
      max_bot_concurrency: Application.fetch_env!(:angler, :max_bot_concurrency)
    ]

    # TODO: Use webhook for prod env
    children = [
      {Finch, name: Angler.Finch},
      {Telegram.Poller, bots: [{Angler.Bot, bot_config}]}
    ]

    opts = [strategy: :one_for_one, name: Angler.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
