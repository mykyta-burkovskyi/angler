defmodule Angler.Pipeline.Producer do
  @moduledoc """
  Broadway producer over the `entries` table.

  Demand from the processors is accumulated and served by claiming due entries
  with `Angler.Entries.claim/1`, which also moves them to `:downloading` and
  counts the attempt. Entries are only claimed while there is demand, but
  processors ask for their next entry as soon as they have handed one to the
  `:telegram` batcher: while uploads are saturated, a processor can hold a claimed
  entry that waits (shown as downloading) until the batcher takes its previous one.

  Claims happen when demand arrives, when `Angler.Entries` announces queued work
  (`:entries_queued`) and on a periodic poll, which picks up retries whose
  `available_at` has passed and covers lost notifications.

  The poll also runs a safety net (at most every `:stale_check_interval`): entries
  in progress that showed no sign of life for `:stale_after` were lost by a crashed
  worker and are queued again (or failed when they have no attempts left), see
  `recover_stale/1`. Workers show they are alive with every change of the entry and
  with heartbeats during long downloads and conversions (see
  `Angler.Pipeline.Job.throttled_progress/3`), so the cutoff only needs to exceed
  the longest step without progress reports, not a whole job.

  Options: `:poll_interval` (ms, default 5 s), `:stale_after` (ms, default 6 h),
  `:stale_check_interval` (ms, default 5 min).
  """
  use GenStage
  @behaviour Broadway.Producer

  import Ecto.Query
  require Logger

  alias Angler.{Entries, Repo, Settings, Storage}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.Feedback
  alias Broadway.Message

  @default_poll_interval 5_000
  @default_stale_after :timer.hours(6)
  @default_stale_check_interval :timer.minutes(5)
  @lost_message "Worker lost"

  @impl GenStage
  def init(opts) do
    :ok = Entries.subscribe_queue()

    state = %{
      pending_demand: 0,
      draining: false,
      poll_timer: nil,
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      stale_after: Keyword.get(opts, :stale_after, @default_stale_after),
      stale_check_interval:
        Keyword.get(opts, :stale_check_interval, @default_stale_check_interval),
      next_stale_check: System.monotonic_time(:millisecond)
    }

    {:producer, schedule_poll(state)}
  end

  @impl GenStage
  def handle_demand(demand, state),
    do: dispatch(%{state | pending_demand: state.pending_demand + demand})

  @impl GenStage
  def handle_info(:entries_queued, state), do: dispatch(state)

  def handle_info(:poll, state) do
    %{state | poll_timer: nil}
    |> check_stale()
    |> schedule_poll()
    |> dispatch()
  end

  def handle_info(_message, state), do: {:noreply, [], state}

  @impl Broadway.Producer
  def prepare_for_draining(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    {:noreply, [], %{state | draining: true, poll_timer: nil}}
  end

  @doc """
  Queues entries in progress again that were last updated (or had a heartbeat)
  more than `older_than_ms` ago (their worker is gone), or fails them with
  `:internal` when they have no attempts left. An entry its worker updates in the
  meantime is left alone. Returns `{requeued_count, failed_count}`.
  """
  @spec recover_stale(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def recover_stale(older_than_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_ms, :millisecond)

    from(e in Entry, where: e.status in ^Entry.active_statuses() and e.updated_at < ^cutoff)
    |> Repo.all()
    |> Enum.reduce({0, 0}, fn entry, {requeued, failed} ->
      case recover(entry) do
        :requeued -> {requeued + 1, failed}
        :failed -> {requeued, failed + 1}
        :skipped -> {requeued, failed}
      end
    end)
  end

  defp recover(entry) do
    if entry.attempts < entry.max_attempts do
      Entries.schedule_retry(entry, :internal, @lost_message, 0)
      :requeued
    else
      entry = Entries.mark_failed(entry, :internal, @lost_message)
      Feedback.failed(entry, :internal, Settings.get())
      Storage.purge(entry)
      :failed
    end
  rescue
    # The entry left its claim since it was read (finished, retried or claimed
    # again), see Entries.update!/2.
    Ecto.StaleEntryError -> :skipped
  end

  defp dispatch(%{draining: true} = state), do: {:noreply, [], state}
  defp dispatch(%{pending_demand: 0} = state), do: {:noreply, [], state}

  defp dispatch(state) do
    messages = state.pending_demand |> claim() |> Enum.map(&to_message/1)
    {:noreply, messages, %{state | pending_demand: state.pending_demand - length(messages)}}
  end

  defp claim(demand) do
    Entries.claim(demand)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error(
        "Could not claim queued entries, retrying on the next poll: " <> Exception.message(error)
      )

      []
  end

  defp to_message(%Entry{} = entry),
    do: %Message{data: entry, acknowledger: Broadway.NoopAcknowledger.init()}

  defp schedule_poll(%{draining: true} = state), do: state

  defp schedule_poll(state),
    do: %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}

  defp check_stale(%{draining: false} = state) do
    now = System.monotonic_time(:millisecond)

    if now >= state.next_stale_check do
      run_stale_check(state.stale_after)
      %{state | next_stale_check: now + state.stale_check_interval}
    else
      state
    end
  end

  defp check_stale(state), do: state

  defp run_stale_check(stale_after) do
    case recover_stale(stale_after) do
      {0, 0} ->
        :ok

      {requeued, failed} ->
        Logger.warning(
          "Recovered entries whose worker was lost: #{requeued} queued again, #{failed} failed"
        )
    end
  rescue
    exception ->
      Logger.error(
        "Stale entry check failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )
  end
end
