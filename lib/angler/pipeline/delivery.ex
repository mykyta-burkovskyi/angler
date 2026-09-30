defmodule Angler.Pipeline.Delivery do
  @moduledoc """
  What the uploads of `Angler.Pipeline.Upload` (videos) and
  `Angler.Pipeline.AlbumUpload` (albums) share once media was sent to Telegram,
  or may have been: the caption to send it with, recording the outcome, keeping
  or deleting the entry's files, settling uploads Telegram never confirmed,
  sending the post text that didn't fit into the caption, and turning a failed
  send into the failure of the message.

  Once media may be in the chat, the entry must never be retried: its outcome is
  recorded right away (while the database can't be reached, the write is retried
  for a while, then in the background), and the message is not failed.

  The post text that didn't fit into the caption is sent only after media that
  is known to be in the chat. When Telegram never confirmed the media, it may
  appear much later or never: the text is not sent on its own then, since it
  would come first, or alone. With a local Bot API server, where uploads often
  end unconfirmed, the media carries the text cut to fit its caption instead
  (see `caption/1`).
  """
  require Logger

  alias Angler.{Entries, Media, Settings, Storage, Telegram}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{Caption, DbRetry, Feedback, RetryPolicy}

  @typedoc """
  How an outcome is recorded: the write (e.g. `&Angler.Entries.mark_done/1`), and
  whether an entry read again shows it was recorded (see
  `Angler.Pipeline.DbRetry.record/4`).
  """
  @type update :: {(Entry.t() -> Entry.t()), (Entry.t() -> boolean())}

  # About 30 s, long enough for a database restart; then in the background.
  @db_retry_delays [500, 1_000, 2_000, 4_000, 8_000, 15_000]

  @doc "Moves the claimed entry to `:uploading` and shows that on the dashboard."
  @spec start(Entry.t()) :: Entry.t()
  def start(%Entry{} = entry) do
    entry = Entries.advance(entry, :uploading)

    Entries.broadcast_progress(entry.id, %{
      stage: :uploading,
      percent: nil,
      detail: "Sending to Telegram"
    })

    entry
  end

  @doc """
  The text to send with the media of `entry`, as `{caption, follow_up}` (see
  `Angler.Pipeline.Caption.split/3`), with the settings of now, not of when the
  entry was claimed: a change applies right away.

  A local Bot API server answers only once it has uploaded the media, and uploads
  that take longer than about 500 s end up unconfirmed (see `Angler.Telegram`)
  while the server goes on and posts them. The follow-up can't safely be sent
  then (see the moduledoc), so in local mode the media also carries a text too
  long for its caption cut to fit it, and the whole text follows once the media
  was delivered.
  """
  @spec caption(Entry.t()) :: {String.t() | nil, String.t() | nil}
  def caption(%Entry{} = entry),
    do: Caption.split(entry, Settings.get(), truncate_caption: Telegram.Config.local_mode?())

  @doc """
  Delays (ms) between attempts to record an outcome in the calling process:
  `context[:db_retry_delays]` (for tests) or about 30 s.
  """
  @spec db_retry_delays(map()) :: [non_neg_integer()]
  def db_retry_delays(context), do: Map.get(context, :db_retry_delays, @db_retry_delays)

  @doc """
  Records the outcome of a send with `update`, then runs `next` with the updated
  entry. Failing the message instead would retry the entry and post the media
  again, so while the database can't be reached this is retried for a while (see
  `db_retry_delays/1`), then in the background. `outcome` names it in logs
  ("delivered", ...). Returns `:ok`; nothing happens when another worker took the
  entry over meanwhile.
  """
  @spec record(Entry.t(), String.t(), map(), update(), (Entry.t() -> term())) :: :ok
  def record(%Entry{} = entry, outcome, context, update, next) do
    delays = db_retry_delays(context)
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

    :ok
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

  @doc """
  For an upload Telegram never confirmed (the request was sent, but not
  answered): the entry fails for good with kind `:telegram`, since the media may
  still appear, and is settled with `settle_unconfirmed/2`. A post text that was
  to follow the media is not sent (see the moduledoc).
  """
  @spec unconfirmed(Entry.t(), Settings.Setting.t(), Telegram.Error.t(), map()) :: :ok
  def unconfirmed(%Entry{} = entry, settings, error, context) do
    Logger.warning(
      "Entry #{entry.id} (#{entry.url}) is not sent again: the media may have been " <>
        "posted, but Telegram did not confirm it (#{Exception.message(error)})"
    )

    text = RetryPolicy.unconfirmed_text()
    recorded? = &(&1.status == :failed and &1.error == text)
    update = {&Entries.mark_failed(&1, :telegram, text), recorded?}

    record(entry, "possibly delivered", context, update, &settle_unconfirmed(&1, settings))
  end

  @doc """
  Sends `follow_up`, the post text that didn't fit into the caption of media that
  is in the chat, as a message of its own replying to the message
  `reply_to_message_id`, or to the original message when that is nil (see
  `Angler.Pipeline.Feedback.follow_up/3`). Nothing when `follow_up` is nil.
  """
  @spec send_follow_up(Entry.t(), String.t() | nil, integer() | nil) :: :ok
  def send_follow_up(%Entry{}, nil, _reply_to_message_id), do: :ok

  def send_follow_up(%Entry{} = entry, follow_up, reply_to_message_id),
    do: Feedback.follow_up(entry, follow_up, reply_to_message_id)

  @doc """
  The post text of `entry` that doesn't fit into a caption with `settings`, and
  follows its media as a message of its own (see
  `Angler.Pipeline.Caption.split/3`), or nil. For media sent before, whose text
  wasn't sent yet (e.g. an album a restart interrupted after a part was
  delivered).
  """
  @spec follow_up_text(Entry.t(), Settings.Setting.t()) :: String.t() | nil
  def follow_up_text(%Entry{} = entry, settings) do
    {_caption, follow_up} = Caption.split(entry, settings)
    follow_up
  end

  @doc """
  Finishes an entry that failed because Telegram never confirmed its upload (see
  `unconfirmed/4`, or at boot for an upload a restart interrupted, see
  `Angler.Pipeline`): clears the reaction without failure feedback, since the
  media may still appear, and keeps the prepared video, or an album's files, like
  delivered ones.

  A local Bot API server may still be uploading those files: it reads them by
  path, and deleting them would make the upload fail. The files are finalized like
  those of a delivered entry (retention and the size cap delete them later). With
  a retention of 0 they are left to the next run of `Angler.Storage.Janitor` in
  local mode, instead of being deleted right away.
  """
  @spec settle_unconfirmed(Entry.t(), Settings.Setting.t()) :: Entry.t()
  def settle_unconfirmed(%Entry{} = entry, settings) do
    Feedback.unconfirmed(entry, settings)

    keep =
      cond do
        entry.reused_file_id ->
          []

        entry.media_kind == :album ->
          Storage.album_files(entry)

        true ->
          Enum.reject([Storage.video_path(entry), Storage.thumbnail_path(entry)], &is_nil/1)
      end

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

  @doc """
  Keeps the files of a delivered video: the prepared `output`. Without an output
  (the video was re-used from an earlier delivery) nothing on disk belongs to the
  delivery, except leftovers of an earlier failed attempt: they are deleted.
  """
  @spec keep_files(Entry.t(), Media.Output.t() | nil) :: Entry.t()
  def keep_files(%Entry{storage_path: nil} = entry, nil), do: entry
  def keep_files(entry, nil), do: Storage.purge(entry)

  def keep_files(entry, %Media.Output{} = output),
    do: Storage.finalize(entry, Enum.reject([output.path, output.thumbnail_path], &is_nil/1))

  @doc """
  The failure (see `Angler.Pipeline.RetryPolicy.telegram_failure/2`) of a send of
  `media` that Telegram refused. When a cached `file_id` was rejected, every
  cached file of the entry's URL is forgotten, so the retry downloads it again.
  """
  @spec failure(Entry.t(), {:path, Path.t()} | {:file_id, String.t()}, Telegram.Error.t()) ::
          RetryPolicy.failure()
  def failure(entry, {:file_id, _id}, error) do
    if Telegram.Error.kind(error) == :invalid_file, do: forget_file_ids(entry.url)
    RetryPolicy.telegram_failure(error, true)
  end

  def failure(_entry, {:path, _path}, error), do: RetryPolicy.telegram_failure(error, false)

  defp forget_file_ids(url) do
    case Entries.find_reusable_file(url) do
      nil ->
        :ok

      cached ->
        Entries.update!(cached, %{telegram_file_id: nil, telegram_file_unique_id: nil})
        forget_file_ids(url)
    end
  end

  @doc """
  The file of a sent Message: the largest size of a photo, or the video (Telegram
  may deliver a video as an animation or a document). `%{}` when there is none;
  never raises on an unexpected response.
  """
  @spec sent_file(term()) :: map()
  def sent_file(%{"photo" => [_ | _] = sizes}) do
    sizes
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(&area/1, fn -> %{} end)
  end

  def sent_file(%{} = sent) do
    Enum.find_value(["video", "animation", "document"], %{}, fn key ->
      if is_map(sent[key]), do: sent[key]
    end)
  end

  def sent_file(_sent), do: %{}

  defp area(%{"width" => width, "height" => height})
       when is_integer(width) and is_integer(height),
       do: width * height

  defp area(_size), do: 0

  @doc """
  The id of a sent Message, or nil when it is unknown: scheduled messages in big
  chats come back with `message_id` 0.
  """
  @spec message_id(term()) :: pos_integer() | nil
  def message_id(%{"message_id" => id}) when is_integer(id) and id > 0, do: id
  def message_id(_sent), do: nil
end
