defmodule Angler.Pipeline.Job do
  @moduledoc """
  The processor step of `Angler.Pipeline` for a claimed entry: re-uses the
  Telegram file of an earlier delivery of the same URL, or the video an earlier
  attempt of this entry already prepared (after a failed upload or a restart), or
  downloads the media and makes it fit the upload limit (`Angler.Media`). The
  message then goes to the `:telegram` batcher (`Angler.Pipeline.Upload`), or is
  failed (see `Angler.Pipeline.Failures`).

  Albums (`media_kind: :album`) are never re-used: every attempt downloads them
  again. One that a restart interrupted after part of it was delivered is never
  sent again (see `Angler.Pipeline.AlbumUpload.finish_partial/3`).

  Failures are reported with `Broadway.Message.failed/2` as `{kind, text}` or
  `{kind, text, retry_after_seconds}`; `Angler.Entries` status changes are made
  explicitly (messages carry a no-op acknowledger).
  """
  require Logger

  alias Angler.{Entries, Media, Settings, Storage}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{AlbumUpload, Feedback, RetryPolicy}
  alias Broadway.Message

  @progress_interval 1_000
  # Shows the producer's stale check that the worker is alive (see
  # `Angler.Entries.heartbeat/1`) while a long download or conversion runs.
  @heartbeat_interval 60_000
  @reused_fields [
    :title,
    :extractor,
    :duration,
    :width,
    :height,
    :video_codec,
    :source_bytes,
    :output_bytes,
    :transcoded,
    :media_kind
  ]

  @doc """
  Prepares the media of the entry in `message.data` and routes the message to the
  `:telegram` batcher with `t:Angler.Pipeline.Upload.t/0` data, or fails it.

  `context` must contain `:media`, the `Angler.Media` implementation.
  """
  @spec process(Message.t(), map()) :: Message.t()
  def process(%Message{data: %Entry{} = entry} = message, %{media: media}) do
    settings = Settings.get()
    first_claim? = Entries.first_claim?(entry)

    if not first_claim? and AlbumUpload.partly_delivered?(entry) do
      # A restart interrupted the upload of this album after part of it was
      # delivered: sending it again would post that part twice. Failures finishes
      # it as sent in part.
      Message.failed(message, {:telegram, "the upload was interrupted"})
    else
      # The reaction stays on the message while the entry is retried.
      entry = if first_claim?, do: first_attempt(entry, settings), else: entry

      case Entries.find_reusable_file(entry.url) do
        %Entry{} = cached -> reuse(message, entry, cached, settings)
        nil -> prepare(message, entry, settings, media)
      end
    end
  end

  # Album items delivered before (the entry is sent again from the dashboard) are
  # not part of this claim cycle.
  defp first_attempt(entry, settings) do
    Feedback.started(entry, settings)
    if entry.media_items == [], do: entry, else: Entries.update!(entry, %{media_items: []})
  end

  defp reuse(message, entry, cached, settings) do
    entry =
      Entries.update!(
        entry,
        cached
        |> Map.take(@reused_fields)
        |> Map.merge(%{reused_file_id: true, media_items: []})
      )

    to_upload(message, %{
      entry: entry,
      video: {:file_id, cached.telegram_file_id},
      output: nil,
      settings: settings
    })
  end

  defp prepare(message, entry, settings, media) do
    case prepared_output(entry, settings) do
      %Media.Output{} = output ->
        Logger.info("Entry #{entry.id}: sending the video prepared by an earlier attempt")

        to_upload(message, %{
          entry: entry,
          video: {:path, output.path},
          output: output,
          settings: settings
        })

      nil ->
        download(message, entry, settings, media)
    end
  end

  # An earlier attempt of this claim cycle may have left a finished video behind
  # (its upload failed, or a restart interrupted it). A first claim (a new entry,
  # or "Send again" from the dashboard) always starts from scratch, and albums
  # are downloaded again.
  defp prepared_output(%Entry{media_kind: :album}, _settings), do: nil

  defp prepared_output(%Entry{output_bytes: bytes, reused_file_id: false} = entry, settings)
       when is_integer(bytes) do
    with false <- Entries.first_claim?(entry),
         true <- bytes <= Settings.upload_limit_bytes(settings),
         video when is_binary(video) <- Storage.video_path(entry),
         {:ok, %File.Stat{size: ^bytes}} <- File.stat(video) do
      %Media.Output{
        path: video,
        size: bytes,
        thumbnail_path: Storage.thumbnail_path(entry),
        duration: entry.duration && round(entry.duration),
        width: entry.width,
        height: entry.height,
        video_codec: entry.video_codec,
        transcoded: entry.transcoded
      }
    else
      _other -> nil
    end
  end

  defp prepared_output(_entry, _settings), do: nil

  defp download(message, entry, settings, media) do
    target_bytes = Settings.upload_limit_bytes(settings)

    with {:ok, dir, entry} <- Storage.prepare_dir(entry),
         {:ok, download} <-
           media.download(entry.url, dir,
             max_source_bytes: Settings.max_source_bytes(settings),
             max_duration: Settings.max_duration_seconds(settings),
             target_bytes: target_bytes,
             final_attempt: entry.attempts >= entry.max_attempts,
             on_progress: throttled_progress(entry, :downloading)
           ),
         entry = downloaded(entry, download),
         {:ok, output} <-
           media.prepare(download, dir,
             target_bytes: target_bytes,
             on_progress: throttled_progress(entry, :processing)
           ) do
      to_upload(message, upload_data(prepared(entry, output), output, settings))
    else
      {:error, %Media.Error{} = error} ->
        Message.failed(message, RetryPolicy.media_failure(error))

      # Angler.Media only returns Media.Error, so this comes from Storage.prepare_dir/1.
      {:error, reason} ->
        Message.failed(message, RetryPolicy.storage_failure(reason))
    end
  end

  defp downloaded(entry, %Media.Download{} = download) do
    metadata =
      download
      |> Map.take([:title, :extractor, :width, :height, :video_codec])
      |> Map.merge(%{duration: to_float(download.duration), source_bytes: download.size})
      |> Map.put(:media_kind, download.kind)
      |> compact()
      # Nothing prepared by an earlier attempt is left: never re-use it.
      |> Map.merge(%{reused_file_id: false, output_bytes: nil, media_items: []})

    entry
    |> Entries.advance(:processing, metadata)
    |> Storage.record_usage()
  end

  defp prepared(entry, %Media.Output{kind: :album} = output) do
    metadata = %{
      output_bytes: output.size,
      width: output.width,
      height: output.height,
      transcoded: output.transcoded,
      duration: nil,
      video_codec: nil,
      media_items: AlbumUpload.media_items(output, entry.storage_path)
    }

    entry
    |> Entries.update!(metadata)
    |> Storage.record_usage()
  end

  defp prepared(entry, %Media.Output{} = output) do
    metadata =
      output
      |> Map.take([:transcoded, :width, :height, :video_codec])
      |> Map.merge(%{duration: to_float(output.duration), output_bytes: output.size})
      |> compact()

    entry
    |> Entries.update!(metadata)
    |> Storage.record_usage()
  end

  defp upload_data(entry, %Media.Output{kind: :album} = output, settings),
    do: AlbumUpload.data(entry, output, settings)

  defp upload_data(entry, %Media.Output{} = output, settings),
    do: %{entry: entry, video: {:path, output.path}, output: output, settings: settings}

  defp to_upload(message, data) do
    message
    |> Message.update_data(fn _entry -> data end)
    |> Message.put_batcher(:telegram)
  end

  @doc """
  Returns an `on_progress` callback for `Angler.Media` that broadcasts the claimed
  entry's progress in `stage` at most once per `:interval` ms (default
  #{@progress_interval}) and records a heartbeat (`Angler.Entries.heartbeat/1`) at
  most once per `:heartbeat_interval` ms (default #{@heartbeat_interval}). The
  callback may be called from any process and never raises.
  """
  @spec throttled_progress(Entry.t(), :downloading | :processing, keyword()) ::
          Media.progress_fun()
  def throttled_progress(%Entry{} = entry, stage, opts \\ []) do
    interval = Keyword.get(opts, :interval, @progress_interval)
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, @heartbeat_interval)
    now = System.monotonic_time(:millisecond)
    # 1: last broadcast, 2: last heartbeat (the claim or stage change just wrote one)
    clock = :atomics.new(2, signed: true)
    :atomics.put(clock, 1, now - interval)
    :atomics.put(clock, 2, now)

    fn progress ->
      now = System.monotonic_time(:millisecond)

      if due?(clock, 1, now, interval) do
        Entries.broadcast_progress(entry.id, %{
          stage: stage,
          percent: progress[:percent],
          detail: progress[:detail]
        })
      end

      if due?(clock, 2, now, heartbeat_interval), do: heartbeat(entry)
      :ok
    end
  end

  defp due?(clock, index, now, interval) do
    previous = :atomics.get(clock, index)
    now - previous >= interval and :atomics.compare_exchange(clock, index, previous, now) == :ok
  end

  defp heartbeat(entry) do
    Entries.heartbeat(entry)
  rescue
    exception ->
      Logger.warning(
        "Could not record the heartbeat of entry #{entry.id}: " <> Exception.message(exception)
      )
  end

  ## Helpers

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp to_float(nil), do: nil
  defp to_float(number) when is_number(number), do: number / 1
end
