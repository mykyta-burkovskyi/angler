defmodule Angler.Pipeline.Upload do
  @moduledoc """
  The `:telegram` batcher step of `Angler.Pipeline`: sends the video prepared by
  `Angler.Pipeline.Job.process/2` (a `t:t/0` in the message data) as a reply, with
  its title as the caption (see `Angler.Pipeline.Caption`), and records the outcome.

  Once `sendVideo` has returned, the video may be in the chat, so the entry must
  never be retried from here on: the outcome is recorded in this step (while the
  database can't be reached, the write is retried for a while, then in the
  background), and the message is not failed. That covers a delivery and an
  upload Telegram never confirmed (the request was sent but not answered): such an
  entry fails for good with kind `:telegram` and without failure feedback, because
  the video may still appear, and keeps its files (see `settle_unconfirmed/2`).
  Other failed sends fail the message (see `Angler.Pipeline.Failures`).
  """
  require Logger

  alias Angler.{Entries, Media, Settings, Storage, Telegram}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{Caption, DbRetry, Feedback, RetryPolicy}
  alias Broadway.Message

  @typedoc "Data of a message routed to the `:telegram` batcher."
  @type t :: %{
          entry: Entry.t(),
          video: {:path, Path.t()} | {:file_id, String.t()},
          output: Media.Output.t() | nil,
          settings: Settings.Setting.t()
        }

  # About 30 s, long enough for a database restart; then in the background.
  @db_retry_delays [500, 1_000, 2_000, 4_000, 8_000, 15_000]

  @doc """
  Sends the video of the message and marks the entry done, or fails the message.
  `context` may contain `:db_retry_delays` (ms between attempts to record the
  outcome while the database can't be reached, first in this process, then in the
  background).
  """
  @spec run(Message.t(), map()) :: Message.t()
  def run(%Message{data: %{entry: entry, video: video} = data} = message, context) do
    entry = Entries.advance(entry, :uploading)

    Entries.broadcast_progress(entry.id, %{
      stage: :uploading,
      percent: nil,
      detail: "Sending to Telegram"
    })

    if match?({:path, _path}, video), do: Feedback.uploading(entry)

    # Read now, not when the entry was claimed: a change applies right away.
    caption = Caption.for_entry(entry, Settings.get())

    case Telegram.send_video(entry.chat_id, video, send_options(entry, data.output, caption)) do
      {:ok, sent} ->
        delivered(entry, data, sent, context)
        message

      {:error, %Telegram.Error{} = error} ->
        if Telegram.Error.kind(error) == :unconfirmed do
          unconfirmed(entry, data, error, context)
          message
        else
          Message.failed(message, failure(entry, video, error))
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
  defp delivered(entry, data, sent, context) do
    file = sent_file(sent)

    attrs = %{
      telegram_file_id: file["file_id"],
      telegram_file_unique_id: file["file_unique_id"],
      reply_message_id: reply_message_id(sent),
      reused_file_id: match?({:file_id, _id}, data.video)
    }

    recorded? = fn current ->
      current.status == :done and current.reply_message_id == attrs.reply_message_id and
        current.telegram_file_unique_id == attrs.telegram_file_unique_id
    end

    update = {&Entries.mark_done(&1, attrs), recorded?}

    record(entry, "delivered", context, update, fn entry ->
      Feedback.succeeded(entry, data.settings)
      Logger.info("Delivered entry #{entry.id} (#{entry.url}) to chat #{entry.chat_id}")
      keep_files(entry, data.output)
    end)
  end

  defp unconfirmed(entry, data, error, context) do
    Logger.warning(
      "Entry #{entry.id} (#{entry.url}) is not sent again: the video may have been " <>
        "posted, but Telegram did not confirm it (#{Exception.message(error)})"
    )

    text = RetryPolicy.unconfirmed_text()
    recorded? = &(&1.status == :failed and &1.error == text)
    update = {&Entries.mark_failed(&1, :telegram, text), recorded?}

    record(entry, "possibly delivered", context, update, &settle_unconfirmed(&1, data.settings))
  end

  @doc """
  Finishes an entry that failed because Telegram never confirmed its upload (here,
  or at boot for an upload a restart interrupted, see `Angler.Pipeline`): clears
  the reaction without failure feedback, since the video may still appear, and
  keeps the prepared video like a delivered one.

  A local Bot API server may still be uploading that file: it reads it by path, and
  deleting it would make the upload fail. The files are finalized like those of a
  delivered entry (retention and the size cap delete them later). With a retention
  of 0 they are left to the next run of `Angler.Storage.Janitor` in local mode,
  instead of being deleted right away.
  """
  @spec settle_unconfirmed(Entry.t(), Settings.Setting.t()) :: Entry.t()
  def settle_unconfirmed(%Entry{} = entry, settings) do
    Feedback.unconfirmed(entry, settings)

    keep =
      if entry.reused_file_id,
        do: [],
        else: Enum.reject([Storage.video_path(entry), Storage.thumbnail_path(entry)], &is_nil/1)

    cond do
      keep == [] ->
        keep_files(entry, nil)

      # Storage.finalize/2 would delete them right away.
      Telegram.Config.local_mode?() and Settings.get().retention_hours == 0 ->
        Storage.record_usage(entry)

      true ->
        Storage.finalize(entry, keep)
    end
  end

  # Records the outcome of a send with `update` (`{fun, recorded?}`, see
  # `Angler.Pipeline.DbRetry.record/4`), then runs `next` with the updated entry.
  # Failing the message instead would retry the entry and post the video again, so
  # while the database can't be reached this is retried for a while, then in the
  # background.
  defp record(entry, outcome, context, update, next) do
    delays = Map.get(context, :db_retry_delays, @db_retry_delays)
    background_delays = Map.get(context, :db_retry_delays, DbRetry.background_delays())

    with {:error, exception} <- try_record(entry, outcome, delays, update, next) do
      Logger.warning(
        "Entry #{entry.id} was #{outcome}, but this can't be recorded yet, " <>
          "trying again in the background: " <> Exception.message(exception)
      )

      DbRetry.async(fn ->
        with {:error, exception} <- try_record(entry, outcome, background_delays, update, next) do
          Logger.error(
            "Entry #{entry.id} was #{outcome}, but this could not be recorded: " <>
              Exception.message(exception)
          )
        end
      end)
    end
  end

  defp try_record(entry, outcome, delays, {update, recorded?}, next) do
    case DbRetry.record(entry, update, recorded?, delays) do
      {:ok, entry} ->
        next.(entry)
        :ok

      {:error, :taken_over} ->
        Logger.warning("Entry #{entry.id} was #{outcome} after another worker took it over")

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Telegram may deliver a video as an animation or a document.
  defp sent_file(%{} = sent) do
    Enum.find_value(["video", "animation", "document"], %{}, fn key ->
      if is_map(sent[key]), do: sent[key]
    end)
  end

  defp sent_file(_sent), do: %{}

  # Scheduled messages in big chats come back with message_id 0.
  defp reply_message_id(%{"message_id" => id}) when is_integer(id) and id > 0, do: id
  defp reply_message_id(_sent), do: nil

  # A re-used file has nothing on disk, except leftovers of an earlier failed attempt.
  defp keep_files(%Entry{storage_path: nil} = entry, nil), do: entry
  defp keep_files(entry, nil), do: Storage.purge(entry)

  defp keep_files(entry, %Media.Output{} = output),
    do: Storage.finalize(entry, Enum.reject([output.path, output.thumbnail_path], &is_nil/1))

  defp failure(entry, {:file_id, _id}, error) do
    if Telegram.Error.kind(error) == :invalid_file, do: forget_file_ids(entry.url)
    RetryPolicy.telegram_failure(error, true)
  end

  defp failure(_entry, {:path, _path}, error), do: RetryPolicy.telegram_failure(error, false)

  # Telegram rejected a cached file_id: forget every cached file of this URL, so
  # the retry downloads the video again.
  defp forget_file_ids(url) do
    case Entries.find_reusable_file(url) do
      nil ->
        :ok

      cached ->
        Entries.update!(cached, %{telegram_file_id: nil, telegram_file_unique_id: nil})
        forget_file_ids(url)
    end
  end
end
