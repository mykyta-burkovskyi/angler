defmodule Angler.Entries.Queue do
  @moduledoc """
  The `entries` table as the pipeline's durable job queue: claiming due entries,
  heartbeats of claimed entries, the transitions of a claimed entry (next stage,
  done, failed, scheduled for a retry), recovery after a restart and the lookup of
  Telegram files that can be sent again. Used through `Angler.Entries`.

  A claim is identified by the entry's `claimed_at`: it is set when a worker claims
  the entry and cleared (or replaced by the next claim) when the entry leaves the
  worker. `Angler.Entries.update!/2` refuses to change an entry in progress whose
  claim changed, so a worker that lost its entry can't overwrite newer state.
  """
  import Ecto.Query

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Repo

  @max_error_length 4_000

  @typedoc "What `recover_orphaned/1` did."
  @type recovery :: %{
          requeued: non_neg_integer(),
          failed: [Entry.t()],
          failed_uploads: [Entry.t()]
        }

  @doc "See `Angler.Entries.claim/1`."
  @spec claim(integer()) :: [Entry.t()]
  def claim(limit) when is_integer(limit) and limit <= 0, do: []

  def claim(limit) when is_integer(limit) do
    now = DateTime.utc_now()

    due =
      from e in Entry,
        where: e.status == :queued and e.available_at <= ^now,
        order_by: [asc: e.available_at, asc: e.id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED",
        select: %{id: e.id}

    # A MATERIALIZED CTE is an optimization fence: the planner can't turn the
    # LIMIT subquery into a nested loop that locks and updates more rows than asked.
    query =
      Entry
      |> with_cte("due", as: ^due, materialized: true)
      |> join(:inner, [e], d in "due", on: d.id == e.id)
      |> select([e], e)
      |> update([e],
        set: [
          status: ^:downloading,
          stage_detail: nil,
          claimed_at: ^now,
          started_at: fragment("coalesce(?, ?)", e.started_at, ^now),
          updated_at: ^now
        ],
        inc: [attempts: 1]
      )

    {_count, entries} = Repo.update_all(query, [])

    entries
    |> Enum.sort_by(& &1.available_at, DateTime)
    |> Enum.map(&Entries.broadcast_updated/1)
  end

  @doc "See `Angler.Entries.first_claim?/1`."
  @spec first_claim?(Entry.t()) :: boolean()
  def first_claim?(%Entry{started_at: %DateTime{} = started_at, claimed_at: %DateTime{} = at}),
    do: DateTime.compare(started_at, at) == :eq

  def first_claim?(%Entry{}), do: true

  @doc "See `Angler.Entries.heartbeat/1`."
  @spec heartbeat(Entry.t()) :: boolean()
  def heartbeat(%Entry{claimed_at: nil}), do: false

  def heartbeat(%Entry{id: id, claimed_at: claimed_at}) do
    query =
      from e in Entry,
        where:
          e.id == ^id and e.claimed_at == ^claimed_at and
            e.status in ^Entry.active_statuses()

    {count, _} = Repo.update_all(query, set: [updated_at: DateTime.utc_now()])
    count == 1
  end

  @doc "See `Angler.Entries.advance/3`."
  @spec advance(Entry.t(), :downloading | :processing | :uploading, map()) :: Entry.t()
  def advance(%Entry{} = entry, stage, attrs \\ %{})
      when stage in [:downloading, :processing, :uploading] do
    Entries.update!(entry, Map.merge(%{stage_detail: nil}, attrs) |> Map.put(:status, stage))
  end

  @doc "See `Angler.Entries.mark_done/2`."
  @spec mark_done(Entry.t(), map()) :: Entry.t()
  def mark_done(%Entry{} = entry, attrs \\ %{}) do
    Entries.update!(
      entry,
      Map.merge(
        %{
          status: :done,
          stage_detail: nil,
          error: nil,
          error_kind: nil,
          claimed_at: nil,
          finished_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  @doc "See `Angler.Entries.mark_failed/3`."
  @spec mark_failed(Entry.t(), Entry.error_kind(), String.t()) :: Entry.t()
  def mark_failed(%Entry{} = entry, kind, message) do
    Entries.update!(entry, %{
      status: :failed,
      stage_detail: nil,
      error_kind: kind,
      error: truncate_error(message),
      claimed_at: nil,
      finished_at: DateTime.utc_now()
    })
  end

  @doc "See `Angler.Entries.schedule_retry/5`."
  @spec schedule_retry(Entry.t(), Entry.error_kind(), String.t(), non_neg_integer(), keyword()) ::
          Entry.t()
  def schedule_retry(%Entry{} = entry, kind, message, delay_ms, opts \\ []) do
    attrs = %{
      status: :queued,
      stage_detail: nil,
      error_kind: kind,
      error: truncate_error(message),
      claimed_at: nil,
      available_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    }

    attrs =
      if Keyword.get(opts, :count_attempt, true),
        do: attrs,
        else: Map.put(attrs, :attempts, max(entry.attempts - 1, 0))

    entry = Entries.update!(entry, attrs)
    Entries.notify_queue()
    entry
  end

  defp truncate_error(nil), do: nil

  defp truncate_error(message) when is_binary(message) do
    if String.length(message) > @max_error_length,
      do: String.slice(message, 0, @max_error_length) <> "…",
      else: message
  end

  defp truncate_error(other), do: truncate_error(inspect(other))

  @doc "See `Angler.Entries.recover_orphaned/1`."
  @spec recover_orphaned(keyword()) :: recovery()
  def recover_orphaned(opts \\ []) do
    now = DateTime.utc_now()
    active = Entry.active_statuses()

    failed_uploads =
      case Keyword.get(opts, :fail_uploads) do
        {kind, message} ->
          fail_all(from(e in Entry, where: e.status == :uploading), kind, message, now)

        nil ->
          []
      end

    failed =
      fail_all(
        from(e in Entry, where: e.status in ^active and e.attempts >= e.max_attempts),
        :internal,
        "Interrupted by a restart after the last attempt",
        now
      )

    {requeued, requeued_entries} =
      Repo.update_all(
        from(e in Entry, where: e.status in ^active, select: e),
        set: [
          status: :queued,
          stage_detail: nil,
          claimed_at: nil,
          available_at: now,
          updated_at: now
        ]
      )

    Enum.each(requeued_entries, &Entries.broadcast_updated/1)
    if requeued > 0, do: Entries.notify_queue()

    %{requeued: requeued, failed: failed, failed_uploads: failed_uploads}
  end

  defp fail_all(query, kind, message, now) do
    {_count, entries} =
      Repo.update_all(select(query, [e], e),
        set: [
          status: :failed,
          stage_detail: nil,
          error_kind: kind,
          error: message,
          finished_at: now,
          claimed_at: nil,
          updated_at: now
        ]
      )

    Enum.map(entries, &Entries.broadcast_updated/1)
  end

  @doc "See `Angler.Entries.find_reusable_file/1`."
  @spec find_reusable_file(String.t()) :: Entry.t() | nil
  def find_reusable_file(url) do
    Repo.one(
      from e in Entry,
        where: e.url == ^url and not is_nil(e.telegram_file_id) and e.status == :done,
        order_by: [desc: e.finished_at],
        limit: 1
    )
  end
end
