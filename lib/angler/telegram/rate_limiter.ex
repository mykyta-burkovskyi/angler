defmodule Angler.Telegram.RateLimiter do
  @moduledoc """
  Keeps outgoing Bot API calls within Telegram's limits (per chat, per group and
  global), and backs off after 429 responses.

  The limiter schedules virtually: `reserve/4` computes the earliest time at which
  a send is allowed, books that slot and returns how long the caller has to wait.
  `acquire/4` then sleeps in the calling process, so the limiter itself never
  blocks and callers are served in the order they asked. A 429 recorded while a
  caller sleeps (`backoff/3`) postpones it: when it wakes up during the backoff,
  it gives its slot back and reserves one after the backoff.

  Rules (defaults, all configurable through `start_link/1` options):

    * global - at most `:global_limit` (25) sends of any kind per rolling
      `:global_window` (1 s)
    * `:message` sends to a chat - at least `:chat_interval` (1050 ms) apart
    * `:message` sends to a group, supergroup or channel - additionally at most
      `:group_limit` (20) per rolling `:group_window` (60 s)
    * `:light` calls (reactions, chat actions) only count toward the global limit
    * `backoff/3` - nothing is sent to a chat (or anywhere) until it expires

  One call can book several messages (`count: n`, e.g. an album of n items,
  which Telegram counts as n messages): all n go out at the reserved slot and
  count toward the global and group windows, and the chat's next message waits
  as if they had been `:chat_interval` apart.

  Every reservation returns its `t:booking/0`. When its messages were not posted
  (Telegram answered 429), `backoff/3` with `release: booking` gives exactly that
  booking back, so the retry doesn't count them twice. The bookings of other
  callers stay: they are sent at their slots, unless they wake up during the
  backoff (see above).

  The chat type decides which rules apply; when it is unknown, negative chat ids
  (groups and channels) get the group rules. Chats idle for longer than
  `:idle_timeout` (2 minutes) are forgotten.
  """
  use GenServer

  @type kind :: :message | :light

  @typedoc """
  A reserved slot (`reserve/4`, `acquire/4`): the chat, the kind, the time and
  the number of messages, and the chat's last message slot before it (so that
  releasing it undoes it exactly). Pass it back as `:release` (`backoff/3`,
  `reserve/4`) when its messages were not posted.
  """
  @type booking :: %{
          chat_id: integer() | nil,
          kind: kind(),
          at: integer(),
          count: pos_integer(),
          last_before: integer() | nil
        }

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
  chat type: "private", "group", "supergroup" or "channel"), and reserves that slot
  (returned as a `t:booking/0`). `kind` is `:message` for sends (per-chat,
  per-group and global limits) or `:light` for reactions / chat actions (global
  limit only).

  Options:

    * `:max_wait` - when the slot is further away than this many milliseconds,
      nothing is reserved and `{:error, {:rate_limited, wait_ms}}` is returned
      instead of waiting (default `:infinity`)
    * `:count` - how many messages the call sends (default 1): from 1 up to the
      smaller of `:group_limit` and `:global_limit`, and only 1 for `:light`
      calls; anything else returns `{:error, :invalid_count}`
    * `:server` - the limiter to use (defaults to this module)
  """
  @spec acquire(integer(), String.t() | nil, kind(), keyword()) ::
          {:ok, booking()} | {:error, {:rate_limited, pos_integer()} | :invalid_count}
  def acquire(chat_id, chat_type, kind \\ :message, opts \\ []) do
    with {:ok, wait, booking} <- reserve(chat_id, chat_type, kind, opts) do
      if wait > 0, do: Process.sleep(wait)

      # A 429 another sender got while this one slept moved the backoff past the
      # reserved slot: sending now would hit the flood wait again (and make Telegram
      # extend it), so wait for a slot after it, giving this one back.
      if wait > 0 and backing_off?(chat_id, opts),
        do: acquire(chat_id, chat_type, kind, Keyword.put(opts, :release, booking)),
        else: {:ok, booking}
    end
  end

  @doc """
  Like `acquire/4`, but returns `{:ok, wait_ms, booking}` right away instead of
  sleeping: the reserved slot starts `wait_ms` milliseconds from now.

  Takes the options of `acquire/4`, and `:release`, a `t:booking/0` of the caller
  that it won't use: it is given back first (whether or not a new slot is
  reserved), like with `backoff/3`.
  """
  @spec reserve(integer(), String.t() | nil, kind(), keyword()) ::
          {:ok, non_neg_integer(), booking()}
          | {:error, {:rate_limited, pos_integer()} | :invalid_count}
  def reserve(chat_id, chat_type, kind \\ :message, opts \\ [])
      when kind in [:message, :light] do
    server = Keyword.get(opts, :server, __MODULE__)
    max_wait = Keyword.get(opts, :max_wait, :infinity)
    count = Keyword.get(opts, :count, 1)
    release = Keyword.get(opts, :release)

    GenServer.call(
      server,
      {:reserve, chat_id, chat_type, kind, max_wait, count, release},
      :infinity
    )
  end

  @doc """
  Records a 429 so that nothing is sent to `chat_id` (or anywhere when nil) for
  `retry_after` seconds.

  Options: `:server`, and `:release`, the `t:booking/0` of the send that got the
  429: Telegram posted none of its messages, so they no longer count toward the
  limits, and when no later message of the chat was booked since, the chat's
  next message only waits for the one booked before them. Other bookings stay.
  """
  @spec backoff(integer() | nil, non_neg_integer(), keyword()) :: :ok
  def backoff(chat_id, retry_after, opts \\ [])
      when is_integer(retry_after) and retry_after >= 0 do
    GenServer.cast(
      Keyword.get(opts, :server, __MODULE__),
      {:backoff, chat_id, retry_after, Keyword.get(opts, :release)}
    )
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
  def handle_call({:reserve, chat_id, chat_type, kind, max_wait, count, release}, _from, state) do
    # Given back whatever happens next: its caller won't send at that slot.
    state = release(state, release)

    # Checked here, not in the caller: a bad count must never crash the limiter.
    if valid_count?(count, kind, state) do
      now = state.now_fun.()
      state = prune_global(state, now)
      chat = Map.get(state.chats, chat_id, %{last: nil, times: [], backoff_until: nil})
      group? = group?(chat_id, chat_type)

      at = earliest(state, chat, group?, kind, count, now)
      wait = at - now

      if max_wait == :infinity or wait <= max_wait do
        booking = %{chat_id: chat_id, kind: kind, at: at, count: count, last_before: chat.last}
        {:reply, {:ok, wait, booking}, book(state, chat_id, chat, group?, kind, count, at)}
      else
        {:reply, {:error, {:rate_limited, wait}}, state}
      end
    else
      {:reply, {:error, :invalid_count}, state}
    end
  end

  def handle_call({:backing_off?, chat_id}, _from, state) do
    chat_backoff = get_in(state.chats, [chat_id, :backoff_until])
    until = max_time(state.backoff_until, chat_backoff)
    {:reply, until != nil and until > state.now_fun.(), state}
  end

  @impl true
  def handle_cast({:backoff, chat_id, retry_after, release}, state) do
    until = state.now_fun.() + retry_after * 1_000
    {:noreply, state |> release(release) |> back_off(chat_id, until)}
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

  defp back_off(state, nil, until),
    do: %{state | backoff_until: max_time(state.backoff_until, until)}

  defp back_off(state, chat_id, until) do
    chats =
      Map.update(
        state.chats,
        chat_id,
        %{last: nil, times: [], backoff_until: until},
        &%{&1 | backoff_until: max_time(&1.backoff_until, until)}
      )

    %{state | chats: chats}
  end

  # Undoes `booking`, whose messages were not posted: they leave the global and
  # group windows, and unless a later message of the chat was booked since (its
  # slot stays), the chat's next message only waits for the one booked before.
  # Anything else (nil, or a malformed value) releases nothing.
  defp release(state, %{kind: kind, at: at, count: count} = booking)
       when kind in [:message, :light] and is_integer(at) and is_integer(count) and count > 0 do
    released = List.duplicate(at, count)
    state = %{state | global: state.global -- released}

    chat_id = booking[:chat_id]

    with :message <- kind,
         %{last: last, times: times} = chat <- Map.get(state.chats, chat_id),
         last_before when is_integer(last_before) or is_nil(last_before) <-
           booking[:last_before] do
      last = if last == at + (count - 1) * state.chat_interval, do: last_before, else: last
      chat = %{chat | last: last, times: times -- released}
      %{state | chats: Map.put(state.chats, chat_id, chat)}
    else
      _other -> state
    end
  end

  defp release(state, _booking), do: state

  ## Scheduling

  defp valid_count?(1, _kind, _state), do: true

  defp valid_count?(count, :message, state) when is_integer(count),
    do: count >= 1 and count <= min(state.group_limit, state.global_limit)

  defp valid_count?(_count, _kind, _state), do: false

  # n events at the same time t fit a window of `limit` exactly when one event at
  # t fits it with `limit - n + 1`.
  defp earliest(state, chat, group?, kind, count, now) do
    now
    |> max_time(state.backoff_until)
    |> max_time(chat.backoff_until)
    |> chat_slot(chat, group?, kind, count, state)
    |> window_slot(state.global, state.global_limit - count + 1, state.global_window)
  end

  defp chat_slot(t, _chat, _group?, :light, _count, _state), do: t

  defp chat_slot(t, chat, group?, :message, count, state) do
    t = if chat.last, do: max(t, chat.last + state.chat_interval), else: t

    if group?,
      do: window_slot(t, chat.times, state.group_limit - count + 1, state.group_window),
      else: t
  end

  # Earliest time >= t at which one more event keeps every half-open window of
  # `window` ms at `limit` events or fewer. `times` is sorted; it may contain
  # future reservations, so a slot may be found before them. It doesn't have to
  # keep the rule itself: n events booked at once fit exactly where one event
  # fits `limit - n + 1`, a rule the earlier bookings may break.
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

  # `count` messages all go out at `at`; the chat's next message waits as if they
  # had been sent `chat_interval` apart.
  defp book(state, chat_id, chat, group?, kind, count, at) do
    state = %{state | global: insert_sorted(state.global, at, count)}

    case kind do
      :light ->
        state

      :message ->
        times =
          if group?,
            do: Enum.take(chat.times ++ List.duplicate(at, count), -state.group_limit),
            else: []

        last = at + (count - 1) * state.chat_interval
        %{state | chats: Map.put(state.chats, chat_id, %{chat | last: last, times: times})}
    end
  end

  defp prune_global(state, now) do
    %{state | global: Enum.drop_while(state.global, &(&1 <= now - state.global_window))}
  end

  defp insert_sorted(times, at, count) do
    {before, later} = Enum.split_while(times, &(&1 <= at))
    before ++ List.duplicate(at, count) ++ later
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
