defmodule Angler.Bot do
  alias Angler.UrlExtractor
  use Telegram.Bot

  @impl Telegram.Bot
  def handle_update(
        %{
          "message" => %{
            "entities" => message_entities,
            "text" => message_text,
            "chat" => %{"id" => chat_id, "username" => username},
            "message_id" => message_id
          }
        },
        token
      ) do
    message_entities |> UrlExtractor.extract(message_text) |> IO.inspect()

    Telegram.Api.request(token, "sendMessage",
      chat_id: chat_id,
      reply_to_message_id: message_id,
      text: "Hello #{username}!"
    )
  end

  def handle_update(_update, _token) do
    :ok
  end
end
