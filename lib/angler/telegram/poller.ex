defmodule Angler.Telegram.Poller do
  @moduledoc """
  Long-polls `getUpdates` and hands every update to
  `Angler.Telegram.Updates.handle_safely/1`. Started (and linked) by
  `Angler.Telegram.Receiver` in polling mode, once the webhook is removed.

  An update is confirmed (by asking for the next offset) once it was handled, or
  logged as impossible to handle. After a storage failure the rest of the batch is
  left for later and polling resumes at the failed update after `:storage_delay`.
  Failed `getUpdates` calls are retried with exponential backoff, and 409 conflicts
  (another instance polls with the same token, or a webhook was set) after
  `:conflict_delay`.

  Options:

    * `:owner` - the `Angler.Telegram.Receiver` told about errors as
      `{:poller_error, message | nil}` (nil once polling works again) and about
      handled updates with `Angler.Telegram.Receiver.update_received/2` (once per batch)
    * `:offset` - first update id to fetch (default: the oldest unconfirmed one)
    * `:timeout` - long poll timeout in seconds (default 50, Telegram's maximum)
    * `:error_delay`, `:max_error_delay` - backoff after failed requests in ms
      (default 2 s, doubling up to 60 s)
    * `:conflict_delay` - wait after a 409 in ms (default 10 s)
    * `:storage_delay` - wait after a storage failure in ms (default 5 s)
  """
  use GenServer, restart: :temporary

  require Logger

  alias Angler.Telegram
  alias Angler.Telegram.{Error, Receiver, Updates}

  @defaults [
    timeout: 50,
    error_delay: 2_000,
    max_error_delay: 60_000,
    conflict_delay: 10_000,
    storage_delay: 5_000
  ]

  @doc "Starts a linked poller; see the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state =
      @defaults
      |> Keyword.merge(Keyword.take(opts, Keyword.keys(@defaults)))
      |> Map.new()
      |> Map.merge(%{
        owner: Keyword.get(opts, :owner),
        offset: Keyword.get(opts, :offset),
        failures: 0,
        error: nil
      })

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: poll(state)

  @impl true
  def handle_info(:poll, state), do: poll(state)

  defp poll(state) do
    case Telegram.get_updates(state.offset,
           timeout: state.timeout,
           allowed_updates: Updates.allowed_updates()
         ) do
      {:ok, updates} when is_list(updates) ->
        handle_batch(updates, state)

      {:ok, other} ->
        failed(state, "unexpected getUpdates result: #{inspect(other, limit: 5)}")

      {:error, %Error{code: 409} = error} ->
        message =
          "#{Exception.message(error)} - another instance of this bot is polling with the " <>
            "same token, or a webhook is set"

        Logger.warning("Telegram polling paused: #{message}")
        wait(report(state, message), state.conflict_delay)

      {:error, error} ->
        failed(state, Exception.message(error))
    end
  end

  defp handle_batch(updates, state) do
    case process(updates, state.offset) do
      {:ok, offset, handled} ->
        received(state, handled)
        {:noreply, report(%{state | offset: offset, failures: 0}, nil), {:continue, :poll}}

      {:error, offset, handled, message} ->
        received(state, handled)
        wait(report(%{state | offset: offset}, message), state.storage_delay)
    end
  end

  # Confirms handled updates by advancing the offset past them; stops at the first
  # update that could not be stored so it is fetched again. Counts handled updates.
  defp process(updates, offset) do
    Enum.reduce_while(updates, {:ok, offset, 0}, fn update, {:ok, offset, handled} ->
      case Updates.handle_safely(update) do
        :ok ->
          {:cont, {:ok, next_offset(update, offset), handled + 1}}

        {:error, message} ->
          {:halt, {:error, update["update_id"] || offset, handled, message}}
      end
    end)
  end

  defp received(%{owner: owner}, handled) when owner != nil and handled > 0,
    do: Receiver.update_received(owner, DateTime.utc_now())

  defp received(_state, _handled), do: :ok

  defp next_offset(%{"update_id" => update_id}, _offset) when is_integer(update_id),
    do: update_id + 1

  defp next_offset(_update, offset), do: offset

  defp failed(state, message) do
    delay = min(state.error_delay * 2 ** state.failures, state.max_error_delay)
    Logger.warning("Telegram getUpdates failed: #{message}; retrying in #{delay} ms")
    wait(report(%{state | failures: state.failures + 1}, message), delay)
  end

  defp wait(state, delay) do
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp report(%{error: error} = state, error), do: state

  defp report(state, error) do
    if state.owner, do: send(state.owner, {:poller_error, error})
    %{state | error: error}
  end
end
