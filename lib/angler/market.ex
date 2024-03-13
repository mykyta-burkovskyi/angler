defmodule Angler.Market do
  require Logger

  def sell_produce(video_urls, token, chat_id, message_id) do
    with :error <- send_video_by_url(video_urls, token, chat_id, message_id),
         :error <- send_video_by_stream(video_urls, token, chat_id, message_id) do
      Logger.error("Failed to send video to #{chat_id}")
    else
      :ok ->
        Logger.info(
          "Successfully sent video to chat##{chat_id} in response to message##{message_id}"
        )
    end
  end

  defp send_video_by_url(video_urls, token, chat_id, message_id) do
    Logger.info("Sending video by passing url to Telegram API")

    Enum.reduce_while(video_urls, :error, fn video_url, _acc ->
      case Telegram.Api.request(token, "sendVideo",
             chat_id: chat_id,
             reply_to_message_id: message_id,
             video: video_url
           ) do
        {:ok, _} ->
          {:halt, :ok}

        {:error, error} ->
          Logger.error(
            "Failed to send video by url to chat##{chat_id} in response to message##{message_id}: #{inspect(error)}"
          )

          {:cont, :error}
      end
    end)
  end

  defp send_video_by_stream(video_urls, token, chat_id, message_id) do
    Logger.info("Sending video by passing video stream to Telegram API")

    Enum.reduce_while(video_urls, :error, fn video_url, _acc ->
      case Telegram.Api.request(token, "sendVideo",
             chat_id: chat_id,
             reply_to_message_id: message_id,
             video: {:file_content, get_video_stream(video_url), "tiktok.mp4"}
           ) do
        {:ok, _} ->
          {:halt, :ok}

        {:error, error} ->
          Logger.error(
            "Failed to send video by file to chat##{chat_id} in response to message##{message_id}: #{inspect(error)}"
          )

          {:cont, :error}
      end
    end)
  end

  defp get_video_stream(video_url) do
    Stream.resource(
      fn -> Finch.build(:get, video_url) |> Finch.async_request(Angler.Finch) end,
      fn ref ->
        receive do
          {_ref, {:status, 200}} ->
            Logger.debug("Received 200 status code")
            {[], ref}

          {_ref, {:headers, headers}} ->
            Logger.debug("Received headers: #{inspect(headers)}")
            {[], ref}

          {_ref, {:data, chunk}} ->
            Logger.debug("Received chunk: #{inspect(chunk)}")
            {[chunk], ref}

          {_ref, :done} ->
            Logger.debug("Received done")
            {:halt, ref}

          {_ref, {:error, error}} ->
            Logger.error("Received error: #{inspect(error)}")
            {:halt, ref}

          _ ->
            Logger.error("Received unknown message")
            {:halt, ref}
        end
      end,
      fn ref -> Finch.cancel_async_request(ref) end
    )
    |> Stream.map(& &1)
  end
end
