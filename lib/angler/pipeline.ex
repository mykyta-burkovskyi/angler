defmodule Angler.Pipeline do
  @moduledoc """
  Broadway pipeline that turns queued entries into replies with their media.

      Angler.Pipeline.Producer (claims due entries from Postgres, concurrency 1)
        └─ processors (:download_concurrency, max_demand 1): download + ffmpeg
             └─ batcher :telegram (:upload_concurrency, batch_size 1):
                  sendVideo, or an album (sendMediaGroup / sendPhoto / sendVideo)

  Each message is one `Angler.Entries.Entry`; the steps live in
  `Angler.Pipeline.Job` (processors) and `Angler.Pipeline.Upload` /
  `Angler.Pipeline.AlbumUpload` (batch processors). The entries table is the
  source of truth: the steps move entries through their statuses, and failed
  messages are retried or failed in `handle_failed/2` (`Angler.Pipeline.Failures`,
  according to `Angler.Pipeline.RetryPolicy`). Entries that were in progress when
  the node stopped are queued again when the pipeline starts (or failed, with the
  usual failure feedback, when they have no attempts left). With a local Bot API
  server (`Angler.Telegram.Config.local_mode?/0`), entries a restart interrupted
  while uploading are not sent again: the server keeps uploading on its own and
  posts the media, so they fail like an upload Telegram never confirmed
  (`Angler.Pipeline.Delivery.settle_unconfirmed/2`). A post text too long for the
  caption is not sent on its own then: the media, if it appears, carries it cut
  to fit (see `Angler.Pipeline.Delivery.caption/1`). An upload that was still
  waiting for its rate limiter slot when the node stopped is failed that way too.
  An album a restart interrupted after part of it was delivered is never sent
  again: it fails as sent in part (`Angler.Pipeline.AlbumUpload.finish_partial/3`).

  Configured under `config :angler, Angler.Pipeline` (options given to
  `start_link/1` take precedence):

    * `:enabled` - `false` starts nothing (default `true`)
    * `:download_concurrency` - parallel downloads / transcodes (default 2)
    * `:upload_concurrency` - parallel uploads to Telegram (default 2)
    * `:max_attempts` - read by `Angler.Telegram.Updates` when queueing entries
    * `:media` - the `Angler.Media` implementation (default `Angler.Media`)
    * `:poll_interval` - how often the producer looks for due entries (ms, default 5 s)
    * `:retry_base_delay` - first retry delay, growing 4x per attempt (ms, default 30 s)
    * `:stale_after` - entries in progress without any sign of life for this long are
      recovered (ms, default 6 h, see `Angler.Pipeline.Producer`)
    * `:db_retry_delays` - delays (ms) between attempts to record an outcome while the
      database can't be reached (defaults in `Angler.Pipeline.Delivery` and
      `Angler.Pipeline.DbRetry`; for tests)
    * `:album_retry_delays` - delays (ms) between attempts to send a later part of an
      album that Telegram refused without posting it (default in
      `Angler.Pipeline.AlbumUpload.Sender`; for tests)
    * `:name` - the Broadway name (default `Angler.Pipeline`)
  """
  use Broadway

  require Logger

  alias Angler.{Entries, Settings, Storage, Telegram}
  alias Angler.Pipeline.{AlbumUpload, Delivery, Failures, Feedback, Job, Producer}
  alias Angler.Pipeline.{RetryPolicy, Upload}

  @defaults [
    enabled: true,
    download_concurrency: 2,
    upload_concurrency: 2,
    media: Angler.Media,
    poll_interval: 5_000,
    retry_base_delay: 30_000,
    name: __MODULE__
  ]

  # Grace period for in-flight work on shutdown. Broadway waits this long for the
  # stages to finish, then gives each stage still busy up to this long again, so a
  # stop takes at most about @shutdown * (1 + download + upload concurrency).
  # Entries interrupted after it are queued again on the next boot (uploads in
  # local mode are failed instead, see the moduledoc).
  @shutdown 15_000

  @doc "Child spec for the application supervisor; returns :ignore when disabled."
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: :infinity}

  @doc """
  Starts the pipeline, or returns `:ignore` when it is disabled.

  Nothing else consumes the queue, so entries left in progress by a previous run
  are recovered first (`Angler.Entries.recover_orphaned/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = config(opts)

    cond do
      not config[:enabled] ->
        :ignore

      # Recovering while a pipeline runs would re-queue the entries it works on.
      pid = GenServer.whereis(config[:name]) ->
        {:error, {:already_started, pid}}

      true ->
        recover_orphaned()
        Broadway.start_link(__MODULE__, broadway_options(config))
    end
  end

  @doc "Configured concurrency and whether the pipeline is running, for the dashboard."
  @spec info() :: %{
          running: boolean(),
          download_concurrency: pos_integer(),
          upload_concurrency: pos_integer()
        }
  def info do
    config = config([])

    %{
      running: Process.whereis(__MODULE__) != nil,
      download_concurrency: config[:download_concurrency],
      upload_concurrency: config[:upload_concurrency]
    }
  end

  @impl Broadway
  def handle_message(_processor, message, context), do: Job.process(message, context)

  @impl Broadway
  def handle_batch(:telegram, messages, _batch_info, context),
    do: Enum.map(messages, &Upload.run(&1, context))

  @impl Broadway
  def handle_failed(messages, context) do
    Enum.each(messages, &Failures.handle(&1, context))
    messages
  end

  defp config(opts) do
    @defaults
    |> Keyword.merge(Application.get_env(:angler, __MODULE__, []))
    |> Keyword.merge(opts)
  end

  defp broadway_options(config) do
    [
      name: config[:name],
      shutdown: @shutdown,
      context:
        Map.new(
          Keyword.take(config, [:media, :retry_base_delay, :db_retry_delays, :album_retry_delays])
        ),
      producer: [
        module: {Producer, Keyword.take(config, [:poll_interval, :stale_after])},
        concurrency: 1
      ],
      # Every message takes minutes: never let a processor prefetch more.
      processors: [default: [concurrency: config[:download_concurrency], max_demand: 1]],
      batchers: [telegram: [concurrency: config[:upload_concurrency], batch_size: 1]]
    ]
  end

  defp recover_orphaned do
    # A local Bot API server keeps uploading after the connection is gone and posts
    # the media: sending it again would post it twice (see Angler.Telegram).
    opts =
      if Telegram.Config.local_mode?(),
        do: [fail_uploads: {:telegram, RetryPolicy.unconfirmed_text()}],
        else: []

    %{requeued: requeued, failed: failed, failed_uploads: unconfirmed} =
      Entries.recover_orphaned(opts)

    Enum.each(failed, fn entry -> after_restart(entry, &failed_by_restart/2) end)
    Enum.each(unconfirmed, fn entry -> after_restart(entry, &unconfirmed_by_restart/2) end)

    if requeued > 0 or failed != [] or unconfirmed != [] do
      Logger.info(
        "Recovered entries interrupted by a restart: #{requeued} queued again, " <>
          "#{length(failed)} failed (no attempts left), " <>
          "#{length(unconfirmed)} not sent again (uploading, Telegram did not confirm it)"
      )
    end
  end

  # Like any failed entry: failure feedback in the chat, files deleted. Unless part
  # of its album is in the chat already.
  defp failed_by_restart(entry, settings) do
    if AlbumUpload.partly_delivered?(entry) do
      AlbumUpload.finish_partial(entry, settings, :interrupted)
    else
      Feedback.failed(entry, :internal, settings)
      Storage.purge(entry)
    end
  end

  # The media may still be posted, or may never have been sent: the post text
  # that was to follow it is not sent on its own (see Angler.Pipeline.Delivery).
  defp unconfirmed_by_restart(entry, settings) do
    if AlbumUpload.partly_delivered?(entry) do
      AlbumUpload.finish_partial(entry, settings, :unconfirmed)
    else
      Delivery.settle_unconfirmed(entry, settings)
    end
  end

  defp after_restart(entry, fun) do
    fun.(entry, Settings.get())
  rescue
    exception ->
      Logger.error(
        "Could not clean up entry #{entry.id} after a restart: " <> Exception.message(exception)
      )
  end
end
