defmodule Angler.Pipeline.AlbumUpload do
  @moduledoc """
  The `:telegram` batcher step of `Angler.Pipeline` for an album (`media_kind:
  :album`, see `Angler.Entries.MediaItem`): sends its photos and videos as
  replies, in display order, and records the outcome.

  The album goes out in parts (see `Angler.Pipeline.AlbumUpload.Plan`), one
  request each. The post text is the caption of the first item, or follows the
  album as a message of its own when it is too long for a caption (see
  `Angler.Pipeline.Delivery.caption/1`): once any part was delivered, not when
  the first part was refused or Telegram never confirmed it.

  Like a video (see `Angler.Pipeline.Upload`), nothing may be posted twice:

    * every file is checked before anything is sent; a missing one fails the
      message, so the entry is retried (and downloaded again)
    * the first part is handled like a video: when Telegram refuses it the
      message fails (see `Angler.Pipeline.Failures`); when Telegram never
      confirmed it the entry fails for good
    * once a part is in the chat, the file ids of its items are recorded in
      `media_items` before the next part is sent, and the message never fails
      again. A later part refused without being posted (rate limited, a network
      error) is sent again for up to 10 minutes. When it can't be sent, the
      entry fails for good as sent in part (with failure feedback), or, when
      Telegram never confirmed it, as possibly sent (without)

  An entry whose album was interrupted after a part was recorded (a crash, a
  restart) is never sent again either: `finish_partial/3` fails it the same way
  (see `Angler.Pipeline.Failures`, `Angler.Pipeline.Job` and `Angler.Pipeline`).
  Albums keep their files like videos (`Angler.Storage.album_files/1`).
  """
  require Logger

  alias Angler.{Media, Settings, Telegram}
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Pipeline.{Delivery, Feedback, RetryPolicy}
  alias Angler.Pipeline.AlbumUpload.{Plan, Progress, Sender}
  alias Broadway.Message

  @typedoc "An item of an album to send (see `t:Angler.Telegram.MediaBody.item/0`)."
  @type item :: %{
          type: :photo | :video,
          media: {:path, Path.t()},
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration: number() | nil,
          thumbnail: Path.t() | nil
        }

  @typedoc """
  Data of an album message routed to the `:telegram` batcher: the items in the
  order of the entry's `media_items`.
  """
  @type t :: %{
          entry: Entry.t(),
          album: [item()],
          output: Media.Output.t(),
          settings: Settings.Setting.t()
        }

  @later_parts_deadline 600_000

  @doc """
  Whether part of the album of `entry` was delivered (an item has a file id), so
  the album must never be sent again from scratch in this claim cycle.
  """
  @spec partly_delivered?(Entry.t()) :: boolean()
  def partly_delivered?(%Entry{media_kind: :album, media_items: items}) when is_list(items),
    do: Enum.any?(items, &MediaItem.delivered?/1)

  def partly_delivered?(%Entry{}), do: false

  @doc """
  The `media_items` of an entry for the album `output` prepared in its directory
  `dir`, in display order, with paths relative to `dir` (see
  `Angler.Storage.Album`).
  """
  @spec media_items(Media.Output.t(), Path.t()) :: [MediaItem.t()]
  def media_items(%Media.Output{kind: :album, items: items}, dir) do
    # Item paths are absolute (`Angler.Media.Album` expands the directory).
    dir = Path.expand(dir)

    Enum.map(items, fn item ->
      MediaItem.new(%{
        type: item.type,
        path: Path.relative_to(item.path, dir),
        thumbnail: item.thumbnail_path && Path.relative_to(item.thumbnail_path, dir),
        bytes: item.size,
        width: item.width,
        height: item.height,
        duration: item.duration
      })
    end)
  end

  @doc """
  The message data (`t:t/0`) for the album `output` prepared for `entry`, whose
  `media_items` were built from it (`media_items/2`).
  """
  @spec data(Entry.t(), Media.Output.t(), Settings.Setting.t()) :: t()
  def data(%Entry{} = entry, %Media.Output{kind: :album} = output, settings) do
    album =
      Enum.map(output.items, fn item ->
        %{
          type: item.type,
          media: {:path, item.path},
          width: item.width,
          height: item.height,
          duration: item.duration,
          thumbnail: item.thumbnail_path
        }
      end)

    %{entry: entry, album: album, output: output, settings: settings}
  end

  @doc """
  Sends the album of the message and marks the entry done, or fails it (see the
  moduledoc). `context` may contain `:db_retry_delays` (see
  `Angler.Pipeline.Delivery.db_retry_delays/1`) and `:album_retry_delays` (ms
  between attempts to send a later part again, see
  `Angler.Pipeline.AlbumUpload.Sender.send_later/5`).
  """
  @spec run(Message.t(), map()) :: Message.t()
  def run(%Message{data: %{entry: entry, album: items} = data} = message, context) do
    entry = Delivery.start(entry)

    case check_files(items) do
      {:ok, items} ->
        Feedback.uploading(entry, chat_action(items))
        {caption, follow_up} = Delivery.caption(entry)
        progress = Progress.new(entry, data.settings, context, length(items), follow_up)

        send_first(message, progress, Plan.groups(items, max_request_bytes()), caption)

      {:error, error} ->
        Message.failed(message, RetryPolicy.telegram_failure(error, false))
    end
  end

  @doc """
  Fails an album entry of which only a part was delivered (its `media_items` with
  a file id, see `partly_delivered?/1`), and that must not be sent again: its
  upload was interrupted (`:interrupted`: a restart, a lost worker) or failed for
  `reason` (a text, e.g. a crash). The entry fails with kind `:telegram` and
  `Angler.Pipeline.RetryPolicy.partial_text/3`, gets the failure feedback of a
  partial album (`Angler.Pipeline.Feedback.partial/4`) and keeps its files. A
  post text too long for a caption follows the part in the chat.

  With `reason` `:unconfirmed` (a local Bot API server may still post the rest),
  it fails with `Angler.Pipeline.RetryPolicy.partial_unconfirmed_text/2` and is
  settled without failure feedback, see
  `Angler.Pipeline.Delivery.settle_unconfirmed/2`.
  """
  @spec finish_partial(Entry.t(), Settings.Setting.t(), Progress.reason()) :: Entry.t()
  defdelegate finish_partial(entry, settings, reason), to: Progress

  # Nothing was posted before the first part: it fails like a video.
  defp send_first(message, _progress, [], _caption),
    do: Message.failed(message, {:internal, "The album has no items"})

  defp send_first(message, progress, [group | rest], caption) do
    %Progress{entry: entry} = progress

    case Sender.send(entry.chat_id, group, [caption: caption] ++ reply_options(entry)) do
      {:ok, sent} ->
        deadline = System.monotonic_time(:millisecond) + @later_parts_deadline
        progress |> Progress.delivered(group, sent) |> send_rest(rest, deadline)
        message

      {:error, error} ->
        if Telegram.Error.kind(error) == :unconfirmed do
          Delivery.unconfirmed(entry, progress.settings, error, progress.context)
          message
        else
          Message.failed(message, RetryPolicy.telegram_failure(error, false))
        end
    end
  end

  # From here on part of the album is in the chat: nothing may raise or fail the
  # message, or the entry would be retried and post that part again.
  defp send_rest(progress, [], _deadline), do: safely(progress, &Progress.done/1)

  defp send_rest(progress, [group | rest], deadline) do
    case safely(progress, &send_part(&1, group, deadline)) do
      {:ok, progress} -> send_rest(progress, rest, deadline)
      :stopped -> :ok
      {:error, reason} -> safely(progress, &Progress.failed(&1, reason))
    end
  end

  defp send_part(progress, group, deadline) do
    delays = Map.get(progress.context, :album_retry_delays)

    with {:ok, %Progress{entry: entry} = progress} <- Progress.save(progress),
         {:ok, sent} <-
           Sender.send_later(entry.chat_id, group, reply_options(entry), deadline, delays) do
      {:ok, Progress.delivered(progress, group, sent)}
    end
  end

  defp reply_options(entry) do
    [
      reply_to_message_id: entry.message_id,
      message_thread_id: entry.message_thread_id,
      chat_type: entry.chat_type
    ]
  end

  # Runs `fun` with `progress`; a crash is logged and returned as the reason why
  # the rest of the album isn't sent.
  defp safely(%Progress{entry: entry} = progress, fun) do
    fun.(progress)
  catch
    kind, reason ->
      Logger.error(
        "Entry #{entry.id}: sending its album failed after a part was delivered: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, Exception.format_banner(kind, reason, __STACKTRACE__)}
  end

  ## Before sending

  # Every file must be there: `bytes` (with the thumbnail) for the plan, `index`
  # in `media_items`.
  defp check_files(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, checked} ->
      with {:ok, bytes} <- file_size(item.media),
           {:ok, thumbnail_bytes} <- file_size(item.thumbnail) do
        item = Map.merge(item, %{index: index, bytes: bytes + thumbnail_bytes})
        {:cont, {:ok, [item | checked]}}
      else
        {:error, path} -> {:halt, {:error, not_found(path)}}
      end
    end)
    |> then(fn
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      {:error, error} -> {:error, error}
    end)
  end

  defp file_size(nil), do: {:ok, 0}
  defp file_size({:path, path}), do: file_size(path)
  defp file_size({:file_id, _id}), do: {:ok, 0}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      _missing -> {:error, path}
    end
  end

  defp not_found(path) do
    %Telegram.Error{
      method: "sendMediaGroup",
      reason: :enoent,
      description: "album file not found: #{path}"
    }
  end

  defp chat_action(items) do
    if Enum.any?(items, &(&1.type == :video)), do: "upload_video", else: "upload_photo"
  end

  # A local Bot API server reads the files from disk: only their number counts.
  defp max_request_bytes do
    if Telegram.Config.local_mode?(), do: nil, else: Settings.max_upload_mb() * 1_000_000
  end
end
