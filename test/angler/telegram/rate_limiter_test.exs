defmodule Angler.Telegram.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Angler.Telegram.RateLimiter

  @private 111
  @other_private 222
  @group -100_123

  # A limiter with a manual clock: reserve/4 returns waits without sleeping and the
  # test moves time forward, as if the callers had slept.
  setup context do
    clock = :atomics.new(1, signed: true)
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"

    opts =
      [name: name, now_fun: fn -> :atomics.get(clock, 1) end, cleanup_interval: :timer.hours(1)] ++
        Map.get(context, :limits, [])

    pid = start_supervised!({RateLimiter, opts})
    %{clock: clock, server: name, pid: pid}
  end

  defp reserve(ctx, chat_id, chat_type, kind, opts \\ []) do
    RateLimiter.reserve(chat_id, chat_type, kind, [server: ctx.server] ++ opts)
  end

  defp wait!(ctx, chat_id, chat_type, kind \\ :message) do
    {:ok, wait} = reserve(ctx, chat_id, chat_type, kind)
    wait
  end

  defp advance(ctx, ms), do: :atomics.add(ctx.clock, 1, ms)
  defp now(ctx), do: :atomics.get(ctx.clock, 1)

  # Returns once `chat_id`'s last reserved message slot is `slot`.
  defp wait_for_slot(pid, chat_id, slot) do
    unless get_in(:sys.get_state(pid), [:chats, chat_id, :last]) == slot,
      do: wait_for_slot(pid, chat_id, slot)
  end

  describe "messages to a private chat" do
    test "are spaced by the chat interval", ctx do
      assert wait!(ctx, @private, "private") == 0
      assert wait!(ctx, @private, "private") == 1_050
      assert wait!(ctx, @private, "private") == 2_100

      advance(ctx, 1_000)
      assert wait!(ctx, @private, "private") == 2_150

      advance(ctx, 10_000)
      assert wait!(ctx, @private, "private") == 0
    end

    test "don't delay other chats", ctx do
      assert wait!(ctx, @private, "private") == 0
      assert wait!(ctx, @other_private, "private") == 0
      assert wait!(ctx, @other_private, nil) == 1_050
    end

    test "are not limited per minute", ctx do
      for _ <- 1..30 do
        wait = wait!(ctx, @private, "private")
        advance(ctx, wait)
      end

      assert wait!(ctx, @private, "private") == 1_050
    end
  end

  describe "messages to groups" do
    test "are limited to 20 per rolling minute", ctx do
      for i <- 0..19 do
        wait = wait!(ctx, @group, "supergroup")
        assert wait == if(i == 0, do: 0, else: 1_050)
        advance(ctx, wait)
      end

      # 20 sends at 0, 1050, ..., 19950: the 21st waits for the first to leave the window.
      assert now(ctx) == 19_950
      assert wait!(ctx, @group, "supergroup") == 60_000 - 19_950
    end

    test "negative ids of unknown chat type and channels get the group rules", ctx do
      for chat_id <- [-1, -2] do
        for _ <- 1..20,
            do: advance(ctx, wait!(ctx, chat_id, if(chat_id == -1, do: nil, else: "channel")))
      end

      assert wait!(ctx, -1, nil) > 1_050
      assert wait!(ctx, -2, "channel") > 1_050
    end

    test "the chat type wins over the sign of the id", ctx do
      for _ <- 1..20, do: advance(ctx, wait!(ctx, 5, "group"))
      assert wait!(ctx, 5, "group") > 1_050
    end
  end

  describe "global limit" do
    test "allows 25 sends per rolling second across chats", ctx do
      for chat_id <- 1..25, do: assert(wait!(ctx, chat_id, "private") == 0)
      assert wait!(ctx, 26, "private") == 1_000

      advance(ctx, 400)
      assert wait!(ctx, 27, "private") == 600
    end

    test "counts light calls too, which skip the per-chat rules", ctx do
      for _ <- 1..25, do: assert(wait!(ctx, @private, "private", :light) == 0)
      assert wait!(ctx, @other_private, "private") == 1_000
    end

    @tag limits: [global_limit: 2]
    test "fits calls in before later reservations when there is room", ctx do
      # Messages to one chat reserve 0, 1050 and 2100.
      assert Enum.map(1..3, fn _ -> wait!(ctx, @private, "private") end) == [0, 1_050, 2_100]

      # Light calls fit between them as long as no second holds more than 2 calls.
      assert wait!(ctx, @other_private, "private", :light) == 0
      assert wait!(ctx, @other_private, "private", :light) == 1_000
      assert wait!(ctx, @other_private, "private", :light) == 2_000
    end
  end

  describe "window_slot/4" do
    test "returns the earliest time keeping every window within the limit" do
      assert RateLimiter.window_slot(0, [], 2, 1_000) == 0
      assert RateLimiter.window_slot(150, [0, 100], 2, 1_000) == 1_000
      assert RateLimiter.window_slot(0, [5_000, 5_100], 2, 1_000) == 0
      assert RateLimiter.window_slot(4_100, [5_000, 5_100], 2, 1_000) == 4_100
      assert RateLimiter.window_slot(4_200, [5_000, 5_100], 2, 1_000) == 6_000
    end

    test "agrees with a brute force search on random schedules" do
      for _ <- 1..300 do
        limit = Enum.random(1..3)
        window = Enum.random(1..15)

        times =
          Enum.reduce(1..Enum.random(0..8)//1, [], fn _, times ->
            Enum.sort([RateLimiter.window_slot(Enum.random(0..40), times, limit, window) | times])
          end)

        t = Enum.random(0..40)
        slot = RateLimiter.window_slot(t, times, limit, window)

        assert valid?(Enum.sort([slot | times]), limit, window)
        assert Enum.find(t..slot, &valid?(Enum.sort([&1 | times]), limit, window)) == slot
      end
    end

    defp valid?(sorted, limit, window) do
      sorted
      |> Enum.chunk_every(limit + 1, 1, :discard)
      |> Enum.all?(fn run -> List.last(run) - hd(run) >= window end)
    end
  end

  describe "backoff/3" do
    test "holds back a chat for the given seconds", ctx do
      RateLimiter.backoff(@private, 3, server: ctx.server)

      assert wait!(ctx, @private, "private") == 3_000
      assert wait!(ctx, @private, "private", :light) == 3_000
      assert wait!(ctx, @other_private, "private") == 0
    end

    test "with nil holds back every chat", ctx do
      RateLimiter.backoff(nil, 2, server: ctx.server)

      assert wait!(ctx, @private, "private") == 2_000
      assert wait!(ctx, @group, "group", :light) == 2_000
    end

    test "never shortens an earlier backoff", ctx do
      RateLimiter.backoff(@private, 10, server: ctx.server)
      RateLimiter.backoff(@private, 1, server: ctx.server)

      assert wait!(ctx, @private, "private") == 10_000
    end

    # The manual clock stands still while acquire/4 really sleeps for its slot.
    @tag limits: [chat_interval: 200]
    test "recorded while acquire/4 sleeps makes it wait for a slot after the backoff", ctx do
      assert wait!(ctx, @private, "private") == 0

      # Another sender to the chat gets a 429 once this caller booked its slot at 200.
      start_supervised!(
        {Task,
         fn ->
           wait_for_slot(ctx.pid, @private, 200)
           RateLimiter.backoff(@private, 1, server: ctx.server)
         end}
      )

      assert RateLimiter.acquire(@private, "private", :message,
               server: ctx.server,
               max_wait: 500
             ) == {:error, {:rate_limited, 1_000}}
    end
  end

  describe "max_wait" do
    test "refuses slots further away without reserving them", ctx do
      assert wait!(ctx, @private, "private") == 0

      assert reserve(ctx, @private, "private", :message, max_wait: 500) ==
               {:error, {:rate_limited, 1_050}}

      assert reserve(ctx, @private, "private", :message, max_wait: 1_050) == {:ok, 1_050}
    end
  end

  test "forgets idle chats", ctx do
    wait!(ctx, @private, "private")
    RateLimiter.backoff(@group, 200, server: ctx.server)

    advance(ctx, 121_000)
    send(ctx.pid, :cleanup)

    assert %{chats: chats, global: []} = :sys.get_state(ctx.pid)
    assert Map.keys(chats) == [@group]
  end

  test "acquire/4 sleeps until the reserved slot" do
    name = :"#{__MODULE__}.real_clock"

    start_supervised!(
      Supervisor.child_spec({RateLimiter, name: name, chat_interval: 50}, id: name)
    )

    started = System.monotonic_time(:millisecond)
    assert RateLimiter.acquire(@private, "private", :message, server: name) == :ok
    assert RateLimiter.acquire(@private, "private", :message, server: name) == :ok
    assert System.monotonic_time(:millisecond) - started >= 50

    assert {:error, {:rate_limited, wait}} =
             RateLimiter.acquire(@private, "private", :message, server: name, max_wait: 10)

    assert wait in 11..50
  end
end
