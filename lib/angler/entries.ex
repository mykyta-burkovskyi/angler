defmodule Angler.Entries do
  @moduledoc """
  Processing entries: the durable job queue behind `Angler.Pipeline` and the data
  shown on the dashboard.

  Every change is broadcast on the `"entries"` PubSub topic (see `subscribe/0`):

    * `{:entry_updated, %Entry{}}` - an entry was inserted or changed
    * `{:entry_deleted, id}` - an entry was deleted
    * `{:entry_progress, id, progress}` - transient progress of an active entry,
      `progress` is a map with `:stage` (`:downloading | :processing | :uploading`),
      `:percent` (float 0..100 or nil) and `:detail` (short human readable string or nil)

  Newly queued work is announced on a separate topic (see `subscribe_queue/0`) as
  `:entries_queued`, which wakes up the pipeline producer.

  This module is the entry point; the pipeline's queue operations live in
  `Angler.Entries.Queue` and the dashboard's list and stats queries in
  `Angler.Entries.Listing`. Old entries are pruned by `Angler.Entries.History`.
  """
  import Ecto.Query

  alias Angler.Entries.{Entry, Listing, Queue}
  alias Angler.Repo

  @pubsub Angler.PubSub
  @topic "entries"
  @queue_topic "entries:queue"

  @enqueue_fields [
    :url,
    :source_host,
    :update_id,
    :chat_id,
    :chat_type,
    :chat_title,
    :message_id,
    :message_thread_id,
    :from_id,
    :from_name,
    :max_attempts
  ]

  ## PubSub

  @doc "Subscribes the caller to entry changes and progress updates."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Subscribes the caller to `:entries_queued` notifications."
  def subscribe_queue, do: Phoenix.PubSub.subscribe(@pubsub, @queue_topic)

  @doc "Tells the pipeline producer that there may be queued work."
  def notify_queue, do: Phoenix.PubSub.broadcast(@pubsub, @queue_topic, :entries_queued)

  @doc """
  Broadcasts transient progress for an active entry. Not persisted.
  Callers should throttle this (at most ~1/second per entry).
  """
  def broadcast_progress(entry_id, %{stage: _} = progress) do
    progress = Map.merge(%{percent: nil, detail: nil}, progress)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:entry_progress, entry_id, progress})
  end

  @doc false
  # Every change of an entry is announced; for `Angler.Entries.Queue`.
  def broadcast_updated(%Entry{} = entry) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:entry_updated, entry})
    entry
  end

  ## Ingestion

  @doc """
  Queues links found in a Telegram message.

  Each map must contain `:url`, `:chat_id`, `:chat_type` and `:message_id` and may
  contain the other `#{inspect(@enqueue_fields)}` keys. Links already queued for the
  same chat/message/url (Telegram re-delivering an update) are silently skipped.

  Returns the newly inserted entries only.
  """
  @spec enqueue([map()]) :: {:ok, [Entry.t()]}
  def enqueue([]), do: {:ok, []}

  def enqueue(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.take(@enqueue_fields)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          status: :queued,
          available_at: now,
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, entries} =
      Repo.insert_all(Entry, rows,
        on_conflict: :nothing,
        conflict_target: [:chat_id, :message_id, :url],
        returning: true
      )

    Enum.each(entries, &broadcast_updated/1)
    if entries != [], do: notify_queue()

    {:ok, entries}
  end

  ## Pipeline API

  @doc """
  Atomically claims up to `limit` queued entries that are due, moving them to
  `:downloading` and incrementing `attempts`. Safe to call concurrently
  (`FOR UPDATE SKIP LOCKED`).
  """
  @spec claim(integer()) :: [Entry.t()]
  defdelegate claim(limit), to: Queue

  @doc """
  Whether the claimed `entry` was claimed for the first time since it was queued
  (or re-queued from the dashboard), as opposed to an automatic retry or a
  recovery after a restart.
  """
  @spec first_claim?(Entry.t()) :: boolean()
  defdelegate first_claim?(entry), to: Queue

  @doc """
  Records that the worker holding the claimed `entry` is still alive by touching
  `updated_at` (not broadcast). Returns false, changing nothing, when the entry is
  no longer held by that claim.
  """
  @spec heartbeat(Entry.t()) :: boolean()
  defdelegate heartbeat(entry), to: Queue

  @doc """
  Returns entries held by a worker (e.g. after a crash or an unclean shutdown) back
  to the queue. Entries that already used all their attempts are failed instead.
  Must only be called when no pipeline is running (at boot).

  With `fail_uploads: {kind, message}`, entries interrupted while uploading are
  failed with that error instead (their video may have been posted anyway).

  Returns `%{requeued: count, failed: entries, failed_uploads: entries}`.
  """
  @spec recover_orphaned(keyword()) :: Queue.recovery()
  defdelegate recover_orphaned(opts \\ []), to: Queue

  @doc """
  Finds the Telegram file of the most recent successful delivery of the same URL,
  so it can be re-sent without downloading or uploading again.
  """
  @spec find_reusable_file(String.t()) :: Entry.t() | nil
  defdelegate find_reusable_file(url), to: Queue

  @doc "Moves an active entry to another active stage, optionally updating other fields."
  @spec advance(Entry.t(), :downloading | :processing | :uploading, map()) :: Entry.t()
  defdelegate advance(entry, stage, attrs \\ %{}), to: Queue

  @doc """
  Updates trusted, internally computed fields of an entry (no casting).

  A claimed entry in progress (`Entry.active?/1`) is only changed while it is still
  held by the claim it had when `entry` was read (the same `claimed_at`), otherwise
  `Ecto.StaleEntryError` is raised: a worker that lost its claim (see
  `Angler.Pipeline.Producer.recover_stale/1`) must not overwrite what happened since.
  """
  @spec update!(Entry.t(), map()) :: Entry.t()
  def update!(%Entry{} = entry, attrs) when is_map(attrs) do
    entry
    |> Ecto.Changeset.change(Map.put(attrs, :updated_at, DateTime.utc_now()))
    |> held_by_claim(entry)
    |> Repo.update!()
    |> broadcast_updated()
  end

  # Only claimed entries have a claim to check (Ecto can't filter on nil).
  defp held_by_claim(changeset, %Entry{claimed_at: %DateTime{} = claimed_at} = entry) do
    if Entry.active?(entry),
      do: %{changeset | filters: Map.put(changeset.filters, :claimed_at, claimed_at)},
      else: changeset
  end

  defp held_by_claim(changeset, %Entry{}), do: changeset

  @doc "Marks an entry as successfully delivered."
  @spec mark_done(Entry.t(), map()) :: Entry.t()
  defdelegate mark_done(entry, attrs \\ %{}), to: Queue

  @doc """
  Marks an entry as permanently failed, optionally updating other fields in the
  same write (e.g. the `media_items` of an album that was sent only in part).
  """
  @spec mark_failed(Entry.t(), Entry.error_kind(), String.t(), map()) :: Entry.t()
  defdelegate mark_failed(entry, kind, message, attrs \\ %{}), to: Queue

  @doc """
  Puts an entry back into the queue to be retried after `delay_ms`.

  With `count_attempt: false` the attempt that just ended is given back (the next
  claim counts it again), for failures that only postpone the work.
  """
  @spec schedule_retry(Entry.t(), Entry.error_kind(), String.t(), non_neg_integer(), keyword()) ::
          Entry.t()
  defdelegate schedule_retry(entry, kind, message, delay_ms, opts \\ []), to: Queue

  ## Dashboard API

  @doc """
  Re-queues a failed, cancelled or done entry from scratch. What an earlier
  delivery left (an album's delivered items, the message replying to the link) is
  forgotten: the album is sent whole again (see
  `Angler.Pipeline.AlbumUpload.partly_delivered?/1`).
  """
  @spec retry(Entry.t()) :: {:ok, Entry.t()} | {:error, :not_retryable}
  def retry(%Entry{id: id}) do
    now = DateTime.utc_now()

    query =
      from e in Entry,
        where: e.id == ^id and e.status in [:failed, :cancelled, :done],
        select: e

    case Repo.update_all(query,
           set: [
             status: :queued,
             attempts: 0,
             error: nil,
             error_kind: nil,
             stage_detail: nil,
             media_items: [],
             reply_message_id: nil,
             claimed_at: nil,
             started_at: nil,
             finished_at: nil,
             available_at: now,
             updated_at: now
           ]
         ) do
      {1, [entry]} ->
        notify_queue()
        {:ok, broadcast_updated(entry)}

      {0, _} ->
        {:error, :not_retryable}
    end
  end

  @doc "Cancels a queued entry before a worker picks it up."
  @spec cancel(Entry.t()) :: {:ok, Entry.t()} | {:error, :not_cancellable}
  def cancel(%Entry{id: id}) do
    now = DateTime.utc_now()

    query = from e in Entry, where: e.id == ^id and e.status == :queued, select: e

    case Repo.update_all(query,
           set: [status: :cancelled, finished_at: now, claimed_at: nil, updated_at: now]
         ) do
      {1, [entry]} -> {:ok, broadcast_updated(entry)}
      {0, _} -> {:error, :not_cancellable}
    end
  end

  @doc """
  Deletes an entry that is not being processed. Callers are responsible for
  removing its files first (see `Angler.Storage.purge/1`).
  """
  @spec delete(Entry.t()) :: {:ok, Entry.t()} | {:error, :active}
  def delete(%Entry{id: id}) do
    query =
      from e in Entry,
        where: e.id == ^id and e.status not in ^Entry.active_statuses(),
        select: e

    case Repo.delete_all(query) do
      {1, [entry]} ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:entry_deleted, entry.id})
        {:ok, entry}

      {0, _} ->
        {:error, :active}
    end
  end

  @spec get(Ecto.UUID.t()) :: Entry.t() | nil
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Entry, uuid)
      :error -> nil
    end
  end

  @spec get!(Ecto.UUID.t()) :: Entry.t()
  def get!(id), do: Repo.get!(Entry, id)

  @doc """
  Lists entries newest first.

  Options:

    * `:filter` - `:all` (default), `:active` (queued or in progress), or a status atom
    * `:search` - case-insensitive substring matched against url, title, chat title and sender
    * `:before` - an `%Entry{}` cursor; only entries older than it are returned
    * `:limit` - defaults to 50
  """
  @spec list(keyword()) :: [Entry.t()]
  defdelegate list(opts \\ []), to: Listing

  @doc "Number of entries per status, with every status present."
  @spec count_by_status() :: %{Entry.status() => non_neg_integer()}
  defdelegate count_by_status, to: Listing

  @doc """
  Aggregate numbers for the dashboard header: `total`, `delivered_24h` and
  `failed_24h` (entries finished in the last 24 hours) and `by_status` (see
  `count_by_status/0`). Stored bytes are reported by `Angler.Storage.usage/0`.
  """
  @spec stats() :: Listing.stats()
  defdelegate stats, to: Listing
end
