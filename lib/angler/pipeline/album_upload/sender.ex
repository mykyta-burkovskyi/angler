defmodule Angler.Pipeline.AlbumUpload.Sender do
  @moduledoc """
  Sends one part of an album (see `Angler.Pipeline.AlbumUpload.Plan`) for
  `Angler.Pipeline.AlbumUpload`: 2 to 10 items with `sendMediaGroup`, a lone
  photo with `sendPhoto` and a lone video with `sendVideo`.

  The parts after the first go out while the first is already in the chat, so
  they must not fail for errors that prove nothing was posted: `send_later/5`
  sends them again (for a while) when Telegram or the local rate limiter refused
  them, or the request couldn't be sent completely.
  """
  alias Angler.Pipeline.AlbumUpload
  alias Angler.Telegram

  # A later part may wait behind the first part's rate limiter slots (one per
  # item, and in groups 20 messages a minute).
  @later_max_wait 120_000
  @retry_delays [1_000, 2_000, 5_000, 10_000, 30_000]

  @typedoc "The sent Messages, one per item, or why nothing was sent."
  @type result :: {:ok, [term()]} | {:error, Telegram.Error.t()}

  @doc """
  Sends `items` (a part of an album) to `chat_id` with the options of
  `Angler.Telegram.send_media_group/3` (`:caption` is the first item's). Returns
  the sent Messages, one per item.
  """
  @spec send(integer(), [AlbumUpload.item()], keyword()) :: result()
  def send(chat_id, [%{type: :photo} = item], opts),
    do: chat_id |> Telegram.send_photo(item.media, opts) |> listed()

  def send(chat_id, [%{type: :video} = item], opts) do
    video_opts = [
      duration: item.duration,
      width: item.width,
      height: item.height,
      thumbnail: item.thumbnail,
      supports_streaming: true
    ]

    chat_id |> Telegram.send_video(item.media, opts ++ video_opts) |> listed()
  end

  def send(chat_id, items, opts) do
    items =
      Enum.map(items, &Map.take(&1, [:type, :media, :width, :height, :duration, :thumbnail]))

    chat_id |> Telegram.send_media_group(items, opts) |> listed()
  end

  defp listed({:ok, sent}) when is_list(sent), do: {:ok, sent}
  defp listed({:ok, sent}), do: {:ok, [sent]}
  defp listed({:error, error}), do: {:error, error}

  @doc """
  Sends a part after the first, like `send/3`, without notification (the first
  part notified the chat) and waiting up to 2 minutes for the rate limiter.

  While it fails without having posted anything (`:rate_limited`, or `:network`:
  the request wasn't sent completely), it is sent again after `retry_after` or
  the next of `delays` (ms; the last one repeats), until `deadline` (monotonic
  ms). When the message to reply to is gone (Telegram refuses such replies in
  forum topics), it is sent once more without replying.
  """
  @spec send_later(integer(), [AlbumUpload.item()], keyword(), integer(), [pos_integer()] | nil) ::
          result()
  def send_later(chat_id, items, opts, deadline, delays \\ nil) do
    max_wait = min(@later_max_wait, max(deadline - now(), 0))
    opts = Keyword.merge(opts, disable_notification: true, max_wait: max_wait)

    with {:error, error} = failed <- send(chat_id, items, opts) do
      case again(error, opts, delays || @retry_delays) do
        {:retry, wait, opts, delays} ->
          if now() + wait < deadline do
            Process.sleep(wait)
            send_later(chat_id, items, opts, deadline, delays)
          else
            failed
          end

        :give_up ->
          failed
      end
    end
  end

  defp again(error, opts, delays) do
    case Telegram.Error.kind(error) do
      :reply_not_found ->
        if Keyword.has_key?(opts, :reply_to_message_id),
          do: {:retry, 0, Keyword.delete(opts, :reply_to_message_id), delays},
          else: :give_up

      # A missing file won't come back.
      :network when error.reason == :enoent ->
        :give_up

      kind when kind in [:rate_limited, :network] ->
        {delay, delays} = next_delay(delays)
        {:retry, max((error.retry_after || 0) * 1_000, delay), opts, delays}

      _other ->
        :give_up
    end
  end

  defp next_delay([delay]), do: {delay, [delay]}
  defp next_delay([delay | delays]), do: {delay, delays}

  defp now, do: System.monotonic_time(:millisecond)
end
