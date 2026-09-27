defmodule Angler.Telegram.RateLimiter do
  @moduledoc """
  Keeps outgoing Bot API calls within Telegram's limits (per chat, per group and
  global), and backs off after 429 responses.

  The limiter schedules virtually: `reserve/4` computes the earliest time at which
  a send is allowed, books that slot and returns how long the caller has to wait.
  `acquire/4` then sleeps in the calling process, so the limiter itself never
  blocks and callers are served in the order they asked. A 429 recorded while a
  caller sleeps (`backoff/2`) postpones it: it reserves a slot after the backoff.

  Rules (defaults, all configurable through `start_link/1` options):

    * global - at most `:global_limit` (25) sends of any kind per rolling
      `:global_window` (1 s)
    * `:message` sends to a chat - at least `:chat_interval` (1050 ms) apart
    * `:message` sends to a group, supergroup or channel - additionally at most
      `:group_limit` (20) per rolling `:group_window` (60 s)
    * `:light` calls (reactions, chat actions) only count toward the global limit
    * `backoff/2` - nothing is sent to a chat (or anywhere) until it expires

  The chat type decides which rules apply; when it is unknown, negative chat ids
  (groups and channels) get the group rules. Chats idle for longer than
  `:idle_timeout` (2 minutes) are forgotten.
  """
  use GenServer

  @type kind :: :message | :light

  @defaults [
    global_limit: 25,
    global_window: 1_000,
    chat_interval: 1_050,
    group_limit: 20,
    group_window: 60_000,
    idle_timeout: 120_000,
    cleanup_interval: 60_000
  ]

  @group_types ["group", "supergroup", "channel"]

  @doc """
  Starts the limiter. Options: `:name` (defaults to this module), the limits
  listed in the moduledoc, `:cleanup_interval` (ms) and `:now_fun`, a zero-arity
  function returning the current time in milliseconds (for tests; defaults to
  monotonic time).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Blocks the caller until a call to `chat_id` is allowed (`chat_type` is Telegram's
  chat type: "private", "group", "supergroup" or "channel"), and reserves that slot.
  `kind` is `:message` for sends (per-chat, per-group and global limits) or `:light`
  for reactions / chat actions (global limit only).

  Options:

    * `:max_wait` - when the slot is further away than this many milliseconds,
      nothing is reserved and `{:error, {:rate_limited, wait_ms}}` is returned
      instead of waiting (default `:infinity`)
    * `:server` - the limiter to use (defaults to this module)
  """
  @spec acquire(integer(), String.t() | nil, kind(), keyword()) ::
          :ok | {:error, {:rate_limited, pos_integer()}}
  def acquire(chat_id, chat_type, kind \\ :message, opts \\ []) do
    with {:ok, wait} <- reserve(chat_id, chat_type, kind, opts) do
      if wait > 0, do: Process.sleep(wait)

      # A 429 another sender got while this one slept moved the backoff past the
      # reserved slot: sending now would hit the flood wait again (and make Telegram
      # extend it), so wait for a slot after it.
      if wait > 0 and backing_off?(chat_id, opts),
        do: acquire(chat_id, chat_type, kind, opts),
        else: :ok
    end
  end

  @doc """
  Like `acquire/4`, but returns `{:ok, wait_ms}` right away instead of sleeping:
  the reserved slot starts `wait_ms` milliseconds from now.
  """
  @spec reserve(integer(), String.t() | nil, kind(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def reserve(chat_id, chat_type, kind \\ :message, opts \\ [])
      when kind in [:message, :light] do
    server = Keyword.get(opts, :server, __MODULE__)
    max_wait = Keyword.get(opts, :max_wait, :infinity)

    GenServer.call(server, {:reserve, chat_id, chat_type, kind, max_wait}, :infinity)
  end

  @doc "Records a 429 so that nothing is sent to `chat_id` (or anywhere when nil) for `retry_after` seconds."
  @spec backoff(integer() | nil, non_neg_integer(), keyword()) :: :ok
  def backoff(chat_id, retry_after, opts \\ [])
      when is_integer(retry_after) and retry_after >= 0 do
    GenServer.cast(Keyword.get(opts, :server, __MODULE__), {:backoff, chat_id, retry_after})
  end

  defp backing_off?(chat_id, opts) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:backing_off?, chat_id}, :infinity)
  end

  ## Server

  @impl true
  def init(opts) do
    config = @defaults |> Keyword.merge(Keyword.take(opts, Keyword.keys(@defaults))) |> Map.new()

    state =
      Map.merge(config, %{
        now_fun: Keyword.get(opts, :now_fun, &monotonic_now/0),
        # Reserved send times of any kind (sorted); only the last window matters.
        global: [],
        # Nothing at all is sent before this time (global 429).
        backoff_until: nil,
        # chat_id => %{last: time | nil, times: [time], backoff_until: time | nil}
        chats: %{}
      })

    schedule_cleanup(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:reserve, chat_id, chat_type, kind, max_wait}, _from, state) do
    now = state.now_fun.()
    state = prune_global(state, now)
    chat = Map.get(state.chats, chat_id, %{last: nil, times: [], backoff_until: nil})
    group? = group?(chat_id, chat_type)

    at = earliest(state, chat, group?, kind, now)
    wait = at - now

    if max_wait == :infinity or wait <= max_wait do
      {:reply, {:ok, wait}, book(state, chat_id, chat, group?, kind, at)}
    else
      {:reply, {:error, {:rate_limited, wait}}, state}
    end
  end

  def handle_call({:backing_off?, chat_id}, _from, state) do
    chat_backoff = get_in(state.chats, [chat_id, :backoff_until])
    until = max_time(state.backoff_until, chat_backoff)
    {:reply, until != nil and until > state.now_fun.(), state}
  end

  @impl true
  def handle_cast({:backoff, nil, retry_after}, state) do
    until = state.now_fun.() + retry_after * 1_000
    {:noreply, %{state | backoff_until: max_time(state.backoff_until, until)}}
  end

  def handle_cast({:backoff, chat_id, retry_after}, state) do
    until = state.now_fun.() + retry_after * 1_000

    chats =
      Map.update(
        state.chats,
        chat_id,
        %{last: nil, times: [], backoff_until: until},
        &%{&1 | backoff_until: max_time(&1.backoff_until, until)}
      )

    {:noreply, %{state | chats: chats}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = state.now_fun.()
    idle_since = now - state.idle_timeout

    chats =
      Map.reject(state.chats, fn {_chat_id, chat} ->
        max_time(chat.last, chat.backoff_until) < idle_since
      end)

    schedule_cleanup(state)
    {:noreply, %{prune_global(state, now) | chats: chats}}
  end

  ## Scheduling

  defp earliest(state, chat, group?, kind, now) do
    now
    |> max_time(state.backoff_until)
    |> max_time(chat.backoff_until)
    |> chat_slot(chat, group?, kind, state)
    |> window_slot(state.global, state.global_limit, state.global_window)
  end

  defp chat_slot(t, _chat, _group?, :light, _state), do: t

  defp chat_slot(t, chat, group?, :message, state) do
    t = if chat.last, do: max(t, chat.last + state.chat_interval), else: t
    if group?, do: window_slot(t, chat.times, state.group_limit, state.group_window), else: t
  end

  # Earliest time >= t at which one more event keeps every half-open window of
  # `window` ms at `limit` events or fewer. `times` is sorted and satisfies the
  # rule already; it may contain future reservations, so a slot may be found
  # before them.
  #
  # For every run of `limit` consecutive events r_k..r_(k+limit-1) spanning less
  # than `window`, the windows holding all of them cover exactly the times in
  # (max(r_(k-1), r_(k+limit-1) - window), r_k + window): a new event there would
  # be one too many. The runs come in time order, so a single pass that jumps
  # past every run containing t finds the earliest free slot.
  # Public for its unit tests.
  @doc false
  @spec window_slot(integer(), [integer()], pos_integer(), pos_integer()) :: integer()
  def window_slot(t, times, limit, _window) when length(times) < limit, do: t

  def window_slot(t, times, limit, window) do
    [nil | times]
    |> Enum.chunk_every(limit + 1, 1, :discard)
    |> Enum.reduce(t, fn [previous | run], t ->
      first = hd(run)
      last = List.last(run)
      from = if previous, do: max(previous, last - window), else: last - window

      if last - first < window and t > from and t < first + window, do: first + window, else: t
    end)
  end

  defp book(state, chat_id, chat, group?, kind, at) do
    state = %{state | global: insert_sorted(state.global, at)}

    case kind do
      :light ->
        state

      :message ->
        times = if group?, do: Enum.take(chat.times ++ [at], -state.group_limit), else: []
        %{state | chats: Map.put(state.chats, chat_id, %{chat | last: at, times: times})}
    end
  end

  defp prune_global(state, now) do
    %{state | global: Enum.drop_while(state.global, &(&1 <= now - state.global_window))}
  end

  defp insert_sorted(times, at) do
    {before, later} = Enum.split_while(times, &(&1 <= at))
    before ++ [at | later]
  end

  defp group?(_chat_id, type) when type in @group_types, do: true
  defp group?(_chat_id, "private"), do: false
  defp group?(chat_id, _type), do: is_integer(chat_id) and chat_id < 0

  defp max_time(a, nil), do: a
  defp max_time(nil, b), do: b
  defp max_time(a, b), do: max(a, b)

  defp schedule_cleanup(state), do: Process.send_after(self(), :cleanup, state.cleanup_interval)

  defp monotonic_now, do: System.monotonic_time(:millisecond)
end
