defmodule Angler.Pipeline.DbRetry do
  @moduledoc """
  Runs database work again while the database can't be reached (a restart, a
  failover, an exhausted connection pool), for bookkeeping the pipeline must not
  lose: recording that a video was sent, and retrying or failing an entry.
  """
  require Logger

  alias Angler.Entries
  alias Angler.Entries.Entry

  # About half an hour.
  @background_delays [1_000, 2_000, 5_000, 10_000, 30_000] ++ List.duplicate(60_000, 28)

  @doc """
  Runs `fun`. While it raises a database error (`DBConnection.ConnectionError`,
  `Postgrex.Error`), waits for the next of `delays` (ms) and runs it again.

  Returns `{:ok, result}`, or `{:error, exception}` with the last database error
  once `delays` are used up. Other exceptions are raised.
  """
  @spec run((-> result), [non_neg_integer()]) :: {:ok, result} | {:error, Exception.t()}
        when result: term()
  def run(fun, delays) when is_function(fun, 0) and is_list(delays) do
    {:ok, fun.()}
  rescue
    exception in [DBConnection.ConnectionError, Postgrex.Error] ->
      case delays do
        [] ->
          {:error, exception}

        [delay | delays] ->
          Process.sleep(delay)
          run(fun, delays)
      end
  end

  @doc """
  Records an outcome of the claimed `entry` with `update` (e.g.
  `&Angler.Entries.mark_done/1`), retrying database errors like `run/2`.

  A write can be committed although its caller got an error (the connection broke
  before the reply). Its retry then finds the claim gone and raises
  `Ecto.StaleEntryError` (see `Angler.Entries.update!/2`), so the entry is read
  again: when `recorded?` holds for it, the outcome was recorded and it is returned.
  Otherwise another worker took the entry over, and `{:error, :taken_over}` is
  returned.
  """
  @spec record(Entry.t(), (Entry.t() -> Entry.t()), (Entry.t() -> boolean()), [
          non_neg_integer()
        ]) :: {:ok, Entry.t()} | {:error, :taken_over | Exception.t()}
  def record(%Entry{} = entry, update, recorded?, delays)
      when is_function(update, 1) and is_function(recorded?, 1) do
    case run(fn -> try_update(entry, update, recorded?) end, delays) do
      {:ok, {:ok, entry}} -> {:ok, entry}
      {:ok, :taken_over} -> {:error, :taken_over}
      {:error, exception} -> {:error, exception}
    end
  end

  defp try_update(entry, update, recorded?) do
    {:ok, update.(entry)}
  rescue
    Ecto.StaleEntryError ->
      case Entries.get(entry.id) do
        %Entry{} = current -> if recorded?.(current), do: {:ok, current}, else: :taken_over
        nil -> :taken_over
      end
  end

  @doc "Delays (ms) for `run/2` in the background: about half an hour."
  @spec background_delays() :: [non_neg_integer()]
  def background_delays, do: @background_delays

  @doc """
  Runs `fun` in a task under `Angler.TaskSupervisor`, so waiting for the database
  doesn't hold up a pipeline stage. Exceptions are logged. Returns `:ok`.
  """
  @spec async((-> term())) :: :ok
  def async(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(Angler.TaskSupervisor, fn -> run_logged(fun) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Could not start a background task: #{inspect(reason)}")
    end

    :ok
  catch
    :exit, reason ->
      Logger.error("Could not start a background task: " <> Exception.format_exit(reason))
      :ok
  end

  defp run_logged(fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "Background database work failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )
  end
end
