defmodule Angler.Pipeline.Upload do
  @moduledoc """
  The `:telegram` batcher step of `Angler.Pipeline`: sends the video prepared by
  `Angler.Pipeline.Job.process/2` (a `t:t/0` in the message data) as a reply, with
  its title as the caption (see `Angler.Pipeline.Caption`), and records the
  outcome. A title too long for a caption follows the video as a message of its
  own once the video was delivered: not when it was refused, nor when Telegram
  never confirmed it (the video may appear after the text, or never). With a
  local Bot API server, where that is common, the video also carries the title
  cut to fit its caption (see `Angler.Pipeline.Delivery.caption/1`). Albums are
  sent by `Angler.Pipeline.AlbumUpload`.

  Once `sendVideo` has returned, the video may be in the chat, so the entry must
  never be retried from here on: the outcome is recorded in this step (see
  `Angler.Pipeline.Delivery`), and the message is not failed. That covers a
  delivery and an upload Telegram never confirmed (the request was sent but not
  answered): such an entry fails for good with kind `:telegram` and without
  failure feedback, because the video may still appear, and keeps its files (see
  `Angler.Pipeline.Delivery.settle_unconfirmed/2`). Other failed sends fail the
  message (see `Angler.Pipeline.Failures`).
  """
  require Logger

  alias Angler.{Entries, Media, Settings, Telegram}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{AlbumUpload, Delivery, Feedback}
  alias Broadway.Message

  @typedoc "Data of a video message routed to the `:telegram` batcher."
  @type video :: %{
          entry: Entry.t(),
          video: {:path, Path.t()} | {:file_id, String.t()},
          output: Media.Output.t() | nil,
          settings: Settings.Setting.t()
        }

  @typedoc "Data of a message routed to the `:telegram` batcher."
  @type t :: video() | AlbumUpload.t()

  @doc """
  Sends the video of the message and marks the entry done, or fails the message
  (albums: see `Angler.Pipeline.AlbumUpload.run/2`). `context` may contain
  `:db_retry_delays` (ms between attempts to record the outcome while the
  database can't be reached, first in this process, then in the background).
  """
  @spec run(Message.t(), map()) :: Message.t()
  def run(%Message{data: %{album: _items}} = message, context),
    do: AlbumUpload.run(message, context)

  def run(%Message{data: %{entry: entry, video: video} = data} = message, context) do
    entry = Delivery.start(entry)
    if match?({:path, _path}, video), do: Feedback.uploading(entry, "upload_video")

    {caption, follow_up} = Delivery.caption(entry)

    case Telegram.send_video(entry.chat_id, video, send_options(entry, data.output, caption)) do
      {:ok, sent} ->
        delivered(entry, data, sent, follow_up, context)
        message

      {:error, %Telegram.Error{} = error} ->
        if Telegram.Error.kind(error) == :unconfirmed do
          Delivery.unconfirmed(entry, data.settings, error, context)
          message
        else
          Message.failed(message, Delivery.failure(entry, video, error))
        end
    end
  end

  defp send_options(entry, output, caption) do
    [
      reply_to_message_id: entry.message_id,
      message_thread_id: entry.message_thread_id,
      chat_type: entry.chat_type,
      caption: caption,
      duration: entry.duration,
      width: entry.width,
      height: entry.height,
      thumbnail: output && output.thumbnail_path,
      supports_streaming: true
    ]
  end

  # The video is in the chat now: nothing here may fail on an unexpected response.
  defp delivered(entry, data, sent, follow_up, context) do
    file = Delivery.sent_file(sent)

    attrs = %{
      telegram_file_id: file["file_id"],
      telegram_file_unique_id: file["file_unique_id"],
      reply_message_id: Delivery.message_id(sent),
      reused_file_id: match?({:file_id, _id}, data.video)
    }

    recorded? = fn current ->
      current.status == :done and current.reply_message_id == attrs.reply_message_id and
        current.telegram_file_unique_id == attrs.telegram_file_unique_id
    end

    update = {&Entries.mark_done(&1, attrs), recorded?}

    Delivery.record(entry, "delivered", context, update, fn entry ->
      Feedback.succeeded(entry, data.settings)
      Delivery.send_follow_up(entry, follow_up, attrs.reply_message_id)
      Logger.info("Delivered entry #{entry.id} (#{entry.url}) to chat #{entry.chat_id}")
      Delivery.keep_files(entry, data.output)
    end)
  end
end
