defmodule Angler.Pipeline.AlbumUpload.Progress do
  @moduledoc """
  What was delivered of an album while `Angler.Pipeline.AlbumUpload` sends it in
  parts, and recording that:

    * after each part but the last (`save/1`), so that a restart or crash never
      sends the album again (see `Angler.Pipeline.AlbumUpload.partly_delivered?/1`)
    * the outcome, once every part was sent (`done/1`) or when the rest can't be
      (`failed/2`, and `finish_partial/3` for an entry whose upload was
      interrupted)

  Delivered items keep their Telegram file ids in the entry's `media_items`. The
  post text that didn't fit into the caption follows the album once its outcome
  is recorded (`Angler.Pipeline.Delivery.send_follow_up/3`), also when it was
  sent only in part.
  """
  require Logger

  alias Angler.{Entries, Settings, Storage, Telegram}
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Pipeline.{DbRetry, Delivery, Feedback, RetryPolicy}

  @enforce_keys [:entry, :settings, :context, :items, :total]
  defstruct [
    :entry,
    :settings,
    :context,
    :follow_up,
    :items,
    :total,
    sent: 0,
    first_message_id: nil
  ]

  @typedoc """
  An album being sent: `items` are the entry's `media_items` with the file ids of
  the delivered ones, `sent` how many of the `total` items were delivered, and
  `first_message_id` the Message of the first one (nil while unknown).
  """
  @type t :: %__MODULE__{
          entry: Entry.t(),
          settings: Settings.Setting.t(),
          context: map(),
          follow_up: String.t() | nil,
          items: [MediaItem.t()],
          total: non_neg_integer(),
          sent: non_neg_integer(),
          first_message_id: pos_integer() | nil
        }

  @typedoc """
  Why the rest of an album wasn't sent: a Telegram error, `:unconfirmed` (it may
  still appear), `:interrupted` (a restart or a lost worker) or a text.
  """
  @type reason :: Telegram.Error.t() | :unconfirmed | :interrupted | String.t()

  @doc """
  Progress of an album of `total` items that hasn't been sent yet: `context` as in
  `Angler.Pipeline.Delivery.record/5`, `follow_up` the text to send after it.
  """
  @spec new(Entry.t(), Settings.Setting.t(), map(), non_neg_integer(), String.t() | nil) :: t()
  def new(%Entry{} = entry, settings, context, total, follow_up) do
    %__MODULE__{
      entry: entry,
      settings: settings,
      context: context,
      items: entry.media_items,
      total: total,
      follow_up: follow_up
    }
  end

  @doc """
  Notes that the `items` of a part were delivered as the Messages `sent`, one per
  item in order (Telegram's answer): each item (by its `:index` in the entry's
  `media_items`) gets the file id of its Message. Never raises on an unexpected
  answer.
  """
  @spec delivered(t(), [%{index: non_neg_integer()}], [term()]) :: t()
  def delivered(%__MODULE__{} = progress, items, sent) do
    media_items =
      items
      |> Enum.zip(sent)
      |> Enum.reduce(progress.items, fn {item, message}, media_items ->
        List.update_at(media_items, item.index, &with_file(&1, Delivery.sent_file(message)))
      end)

    first_message_id =
      if progress.sent == 0,
        do: Delivery.message_id(List.first(sent)),
        else: progress.first_message_id

    %{
      progress
      | items: media_items,
        sent: progress.sent + length(items),
        first_message_id: first_message_id
    }
  end

  defp with_file(%MediaItem{} = item, %{"file_id" => id} = file) when is_binary(id) do
    unique_id = file["file_unique_id"]
    %{item | file_id: id, file_unique_id: if(is_binary(unique_id), do: unique_id)}
  end

  defp with_file(item, _file), do: item

  @doc """
  Records what was delivered so far, before the next part is sent. While the
  database can't be reached this is retried for a while; then nothing more is
  sent (`:stopped`) and the entry fails as sent in part in the background.
  `:stopped` also when another worker took the entry over.
  """
  @spec save(t()) :: {:ok, t()} | :stopped
  def save(%__MODULE__{entry: entry} = progress) do
    attrs = %{media_items: progress.items, reply_message_id: progress.first_message_id}
    delays = Delivery.db_retry_delays(progress.context)

    # Writing the same progress twice is harmless: a stale claim means that
    # another worker took the entry over.
    case DbRetry.record(entry, &Entries.update!(&1, attrs), fn _entry -> false end, delays) do
      {:ok, entry} ->
        {:ok, %{progress | entry: entry}}

      {:error, :taken_over} ->
        Logger.warning(
          "Entry #{entry.id}: stopped sending its album, another worker took it over"
        )

        :stopped

      {:error, exception} ->
        Logger.warning(
          "Entry #{entry.id}: stopped sending its album, the progress can't be recorded: " <>
            Exception.message(exception)
        )

        DbRetry.async(fn -> failed(progress, "the database could not be reached") end)
        :stopped
    end
  end

  @doc """
  Marks the entry done once every part was delivered, clears the reaction and
  keeps the album's files. Albums are never re-used by later deliveries of the
  same URL: they get no `telegram_file_id`.
  """
  @spec done(t()) :: :ok
  def done(%__MODULE__{} = progress) do
    attrs = %{
      reply_message_id: progress.first_message_id,
      telegram_file_id: nil,
      telegram_file_unique_id: nil,
      reused_file_id: false,
      media_items: progress.items
    }

    recorded? = &(&1.status == :done and &1.reply_message_id == attrs.reply_message_id)

    record(progress, "delivered", {&Entries.mark_done(&1, attrs), recorded?}, fn entry ->
      Feedback.succeeded(entry, progress.settings)
      Logger.info("Delivered album entry #{entry.id} (#{entry.url}) to chat #{entry.chat_id}")
      Storage.finalize(entry, Storage.album_files(entry))
    end)
  end

  @doc """
  Fails the entry for good after a part was delivered and the rest couldn't be
  sent for `reason`, like `finish_partial/3`.
  """
  @spec failed(t(), reason()) :: :ok
  def failed(%__MODULE__{entry: entry} = progress, reason) do
    text = text(reason, progress.sent, progress.total)
    Logger.warning("Entry #{entry.id} (#{entry.url}) failed: #{text}")
    attrs = %{media_items: progress.items, reply_message_id: progress.first_message_id}
    recorded? = &(&1.status == :failed and &1.error_kind == :telegram)
    update = {&Entries.mark_failed(&1, :telegram, text, attrs), recorded?}

    record(progress, "sent in part", update, fn entry ->
      settle(entry, progress.settings, reason, progress.sent, progress.total)
    end)
  end

  defp record(progress, outcome, update, next) do
    Delivery.record(progress.entry, outcome, progress.context, update, fn entry ->
      Delivery.send_follow_up(entry, progress.follow_up, progress.first_message_id)
      next.(entry)
    end)
  end

  @doc "See `Angler.Pipeline.AlbumUpload.finish_partial/3`."
  @spec finish_partial(Entry.t(), Settings.Setting.t(), reason()) :: Entry.t()
  def finish_partial(%Entry{media_items: items} = entry, settings, reason) do
    sent = Enum.count(items, &MediaItem.delivered?/1)
    text = text(reason, sent, length(items))
    Logger.warning("Entry #{entry.id} (#{entry.url}) failed: #{text}")

    entry = Entries.mark_failed(entry, :telegram, text)
    # Its text wasn't sent yet: it follows the part in the chat, like in failed/2.
    follow_up = Delivery.follow_up_text(entry, settings)
    Delivery.send_follow_up(entry, follow_up, entry.reply_message_id)
    settle(entry, settings, reason, sent, length(items))
  end

  defp text(reason, sent, total) do
    if unconfirmed?(reason),
      do: RetryPolicy.partial_unconfirmed_text(sent, total),
      else: RetryPolicy.partial_text(sent, total, reason_text(reason))
  end

  # Files are kept like those of a delivered album.
  defp settle(entry, settings, reason, sent, total) do
    if unconfirmed?(reason) do
      Delivery.settle_unconfirmed(entry, settings)
    else
      Feedback.partial(entry, sent, total, settings)
      Storage.finalize(entry, Storage.album_files(entry))
    end
  end

  defp unconfirmed?(:unconfirmed), do: true
  defp unconfirmed?(%Telegram.Error{} = error), do: Telegram.Error.kind(error) == :unconfirmed
  defp unconfirmed?(_reason), do: false

  defp reason_text(%Telegram.Error{} = error), do: Exception.message(error)
  defp reason_text(:interrupted), do: "the upload was interrupted"
  defp reason_text(text) when is_binary(text), do: text
end
