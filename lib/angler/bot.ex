defmodule Angler.Bot do
  alias Angler.AngleBox
  alias Angler.Market
  alias Angler.UrlExtractor
  use Telegram.Bot

  @impl Telegram.Bot
  def handle_update(
        %{
          "message" => %{
            "entities" => message_entities,
            "text" => message_text,
            "chat" => %{"id" => chat_id},
            "message_id" => message_id
          }
        },
        token
      ) do
    message_entities
    |> UrlExtractor.extract(message_text)
    |> Task.async_stream(
      fn message_url ->
        angle = AngleBox.choose_angle(message_url)

        message_url
        |> angle.fish_out()
        |> Market.sell_produce(token, chat_id, message_id)
      end,
      timeout: 5 * 60_000
    )
    |> Stream.run()
  end

  def handle_update(_update, _token) do
    :ok
  end
end
