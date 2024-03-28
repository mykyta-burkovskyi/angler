defmodule Angler.Market do
  require Logger

  def sell_produce(produce_path, token, chat_id, message_id) do
    Logger.info("Selling produce to chat##{chat_id} in response to message##{message_id}")

    {:ok, _} =
      Telegram.Api.request(token, "sendVideo",
        chat_id: chat_id,
        reply_to_message_id: message_id,
        video: {:file, produce_path}
      )

    Logger.info("Produce sold to chat##{chat_id} in response to message##{message_id}")

    :ok
  end
end
