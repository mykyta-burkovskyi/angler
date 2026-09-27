defmodule Angler.Storage.Janitor do
  @moduledoc """
  Periodically enforces the storage limits (`Angler.Storage.enforce_limits/0`):
  shortly after boot, then at a fixed interval, soon after settings change or new
  files are kept (`schedule_run/0`), and on demand (`run_now/0`) from the dashboard
  and before a download when free disk space is low (`Angler.Storage.prepare_dir/1`).

  Requests made through `schedule_run/0` and settings changes are debounced: all
  requests within the debounce window cause a single run. Errors raised by a run are
  logged and never crash the process.

  Options (merged over `config :angler, Angler.Storage.Janitor`):

    * `:enabled` - `false` makes `start_link/1` return `:ignore` (default `true`)
    * `:initial_delay` - milliseconds before the first run (default 30 seconds)
    * `:interval` - milliseconds between periodic runs (default 10 minutes)
    * `:debounce` - milliseconds to coalesce requested runs (default 5 seconds)
    * `:cleanup` - 0-arity function performing a run
      (default `&Angler.Storage.enforce_limits/0`)
  """
  use GenServer

  require Logger

  alias Angler.Storage

  @empty_result %{purged: 0, freed_bytes: 0}

  @doc "Starts the janitor registered under this module's name, unless disabled."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.merge(Application.get_env(:angler, __MODULE__, []), opts)

    if Keyword.get(opts, :enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc """
  Runs a cleanup now and returns its result. When the janitor is disabled, the
  cleanup runs in the caller instead (with the same error handling).
  """
  @spec run_now() :: Storage.cleanup_result()
  def run_now do
    case Process.whereis(__MODULE__) do
      nil -> safe_cleanup(&Storage.enforce_limits/0)
      pid -> GenServer.call(pid, :run_now, :timer.minutes(5))
    end
  end

  @doc """
  Asks for a (debounced) cleanup run soon. Does nothing when the janitor is not
  running.
  """
  @spec schedule_run() :: :ok
  def schedule_run do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        send(pid, :schedule_run)
        :ok
    end
  end

  @impl true
  def init(opts) do
    :ok = Angler.Settings.subscribe()

    state = %{
      cleanup: Keyword.get(opts, :cleanup, &Storage.enforce_limits/0),
      interval: Keyword.get(opts, :interval, :timer.minutes(10)),
      debounce: Keyword.get(opts, :debounce, :timer.seconds(5)),
      tick: start_timer(Keyword.get(opts, :initial_delay, :timer.seconds(30)), :tick),
      pending: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {result, state} = run(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:timeout, ref, :tick}, %{tick: ref} = state),
    do: {:noreply, run_and_forget(state)}

  def handle_info({:timeout, ref, :debounced}, %{pending: ref} = state),
    do: {:noreply, run_and_forget(state)}

  def handle_info(:schedule_run, state), do: {:noreply, request_run(state)}
  def handle_info({:settings_updated, _setting}, state), do: {:noreply, request_run(state)}

  # Timers that fired right before another run cancelled them, and anything else.
  def handle_info(_message, state), do: {:noreply, state}

  defp request_run(%{pending: nil} = state),
    do: %{state | pending: start_timer(state.debounce, :debounced)}

  defp request_run(state), do: state

  defp run_and_forget(state) do
    {_result, state} = run(state)
    state
  end

  # Every run satisfies pending requests and restarts the periodic interval.
  defp run(state) do
    Enum.each([state.tick, state.pending], &cancel_timer/1)
    result = safe_cleanup(state.cleanup)
    {result, %{state | tick: start_timer(state.interval, :tick), pending: nil}}
  end

  defp safe_cleanup(cleanup) do
    cleanup.()
  catch
    kind, reason ->
      Logger.error("Storage cleanup failed: " <> Exception.format(kind, reason, __STACKTRACE__))
      @empty_result
  end

  defp start_timer(time, kind), do: :erlang.start_timer(time, self(), kind)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: :erlang.cancel_timer(ref, async: true, info: false)
end
