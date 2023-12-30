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
      video_stream = get_video_stream(video_url) |> Stream.map(& &1)

      case Telegram.Api.request(token, "sendVideo",
             chat_id: chat_id,
             reply_to_message_id: message_id,
             video: {:file_content, video_stream, "tiktok.mp4"}
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
      fn ->
        HTTPoison.get!(video_url, [], stream_to: self(), async: :once)
      end,
      fn
        %HTTPoison.AsyncResponse{id: id} = resp ->
          receive do
            %HTTPoison.AsyncStatus{id: ^id} ->
              HTTPoison.stream_next(resp)
              {[], resp}

            %HTTPoison.AsyncHeaders{id: ^id} ->
              HTTPoison.stream_next(resp)
              {[], resp}

            %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
              HTTPoison.stream_next(resp)
              {[chunk], resp}

            %HTTPoison.AsyncEnd{id: ^id} ->
              {:halt, resp}
          after
            5_000 ->
              {:halt, resp}
          end

        _ ->
          {:halt, nil}
      end,
      fn
        %HTTPoison.AsyncResponse{id: id} ->
          :hackney.stop_async(id)

        _ ->
          :ok
      end
    )
  end
end
