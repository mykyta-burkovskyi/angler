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

  defp reserve(ctx, chat_id, chat_type, kind, opts) do
    RateLimiter.reserve(chat_id, chat_type, kind, [server: ctx.server] ++ opts)
  end

  defp wait!(ctx, chat_id, chat_type, kind \\ :message, opts \\ []) do
    {:ok, wait, _booking} = reserve(ctx, chat_id, chat_type, kind, opts)
    wait
  end

  # Reserves a message slot: returns its time and the booking.
  defp book!(ctx, chat_id, chat_type, opts \\ []) do
    {:ok, wait, booking} = reserve(ctx, chat_id, chat_type, :message, opts)
    {now(ctx) + wait, booking}
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

  describe "several messages at once (count)" do
    test "go out together, and the chat's next message waits as if they were spaced",
         ctx do
      assert wait!(ctx, @private, "private", :message, count: 3) == 0
      assert wait!(ctx, @private, "private") == 3 * 1_050

      advance(ctx, 3 * 1_050)
      assert wait!(ctx, @private, "private", :message, count: 10) == 1_050
    end

    test "count toward the group window", ctx do
      assert wait!(ctx, @group, "supergroup", :message, count: 10) == 0
      assert wait!(ctx, @group, "supergroup", :message, count: 10) == 10_500

      # 20 messages in the minute: nothing more until the first ten leave it.
      assert wait!(ctx, @group, "supergroup") == 60_000
    end

    test "fit a group window only when all of them fit", ctx do
      for _ <- 1..15, do: advance(ctx, wait!(ctx, @group, "supergroup"))

      # 15 sends at 0, 1050, ..., 14700: 5 more fit now, 6 have to wait until
      # the first send leaves the window.
      assert now(ctx) == 14_700

      assert reserve(ctx, @group, "supergroup", :message, count: 6, max_wait: 1_050) ==
               {:error, {:rate_limited, 60_000 - 14_700}}

      assert wait!(ctx, @group, "supergroup", :message, count: 5) == 1_050
    end

    @tag limits: [global_limit: 5]
    test "count toward the global limit", ctx do
      assert wait!(ctx, 1, "private", :message, count: 3) == 0
      assert wait!(ctx, 2, "private", :message, count: 3) == 1_000
      assert wait!(ctx, 3, "private", :message, count: 2) == 0
      assert wait!(ctx, 4, "private") == 1_000
    end

    @tag limits: [global_limit: 12]
    test "are refused unless 1 <= count <= min(group_limit, global_limit)", ctx do
      for {kind, count} <- [message: 0, message: -1, message: 13, message: 1.0, light: 2] do
        assert reserve(ctx, @private, "private", kind, count: count) == {:error, :invalid_count}
      end

      # Nothing was booked, and the limiter keeps serving.
      assert wait!(ctx, @private, "private", :message, count: 12) == 0
      assert wait!(ctx, @other_private, "private", :light) == 1_000
    end

    @tag limits: [group_limit: 4]
    test "never exceed the smaller group limit", ctx do
      assert reserve(ctx, @group, "group", :message, count: 5) == {:error, :invalid_count}
      assert wait!(ctx, @group, "group", :message, count: 4) == 0
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

    # n events at once fit where one event fits `limit - n + 1`, even though the
    # earlier bookings (of mixed sizes) break that lower limit.
    test "with limit - n + 1 finds the earliest slot for n events at once" do
      book = fn times, at, n -> Enum.sort(times ++ List.duplicate(at, n)) end

      for _ <- 1..1_000 do
        limit = Enum.random(1..6)
        window = Enum.random(1..15)

        times =
          Enum.reduce(1..Enum.random(0..10)//1, [], fn _, times ->
            n = Enum.random(1..limit)

            book.(
              times,
              RateLimiter.window_slot(Enum.random(0..40), times, limit - n + 1, window),
              n
            )
          end)

        assert valid?(times, limit, window)

        n = Enum.random(1..limit)
        t = Enum.random(0..40)
        slot = RateLimiter.window_slot(t, times, limit - n + 1, window)

        assert valid?(book.(times, slot, n), limit, window)
        assert Enum.find(t..slot, &valid?(book.(times, &1, n), limit, window)) == slot
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

    test "gives back the booking of the send that got the 429", ctx do
      assert {0, album} = book!(ctx, @group, "supergroup", count: 10)

      # Telegram posted none of the ten: they leave the windows, and the chat's
      # next message no longer waits for them.
      advance(ctx, 100)
      RateLimiter.backoff(@group, 1, server: ctx.server, release: album)

      assert %{global: [], chats: %{@group => %{last: nil, times: []}}} =
               :sys.get_state(ctx.pid)

      # The retry books them again, without phantom bookings: ten more fit in the
      # minute, the next message waits for the retried ten to leave it.
      advance(ctx, 1_250)
      assert wait!(ctx, @group, "supergroup", :message, count: 10) == 0
      assert wait!(ctx, @group, "supergroup", :message, count: 10) == 10_500
      assert wait!(ctx, @group, "supergroup") == 60_000
    end

    test "keeps the bookings of other callers waiting for their slot", ctx do
      # An album sent at 0, and another one waiting for its slot at 10500.
      assert {0, _sent} = book!(ctx, @group, "supergroup", count: 10)
      assert {10_500, _waiting} = book!(ctx, @group, "supergroup", count: 10)

      # Another send to the group got a 429 at 2000. The backoff is over before
      # 10500: the waiting album goes out at its slot, it doesn't reserve again.
      advance(ctx, 2_000)
      RateLimiter.backoff(@group, 3, server: ctx.server)

      # 20 messages in the minute: the next ten wait for the first ten to leave it.
      advance(ctx, 9_000)
      assert wait!(ctx, @group, "supergroup", :message, count: 10) == 60_000 - 11_000
    end

    test "keeps the chat interval between the sends that follow", ctx do
      # A video sent at 0; a follow-up text and a failure reply wait for their slots.
      assert {0, video} = book!(ctx, @private, "private")
      assert {1_050, follow_up} = book!(ctx, @private, "private")
      assert {2_100, _reply} = book!(ctx, @private, "private")

      # The video got a 429 (1 s) at 500.
      advance(ctx, 500)
      RateLimiter.backoff(@private, 1, server: ctx.server, release: video)

      # The follow-up wakes up during the backoff: it gives its slot back and
      # reserves another one (as acquire/4 does).
      advance(ctx, 550)
      {follow_up_at, _booking} = book!(ctx, @private, "private", release: follow_up)

      # The video is sent again after the backoff.
      advance(ctx, 700)
      {video_at, _booking} = book!(ctx, @private, "private")

      # The reply wakes up after the backoff and goes out at its slot, 2100.
      sends = Enum.sort([follow_up_at, video_at, 2_100])
      assert sends == [2_100, 3_150, 4_200]
    end

    test "gives back only the released booking of a chat", ctx do
      assert {0, first} = book!(ctx, @group, "supergroup", count: 3)
      assert {3_150, _second} = book!(ctx, @group, "supergroup", count: 2)
      assert wait!(ctx, @other_private, "private") == 0

      RateLimiter.backoff(@group, 0, server: ctx.server, release: first)

      # The second booking and its spacing stay, other chats keep theirs.
      assert %{global: [0, 3_150, 3_150], chats: chats} = :sys.get_state(ctx.pid)
      assert %{last: 4_200, times: [3_150, 3_150]} = chats[@group]
      assert %{last: 0} = chats[@other_private]
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

      # The slot it didn't use was given back: only the first message is booked.
      assert %{global: [0], chats: %{@private => %{last: 0}}} = :sys.get_state(ctx.pid)
    end
  end

  describe "max_wait" do
    test "refuses slots further away without reserving them", ctx do
      assert wait!(ctx, @private, "private") == 0

      assert reserve(ctx, @private, "private", :message, max_wait: 500) ==
               {:error, {:rate_limited, 1_050}}

      assert {:ok, 1_050, _booking} = reserve(ctx, @private, "private", :message, max_wait: 1_050)
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
    assert {:ok, first} = RateLimiter.acquire(@private, "private", :message, server: name)
    assert {:ok, second} = RateLimiter.acquire(@private, "private", :message, server: name)
    assert System.monotonic_time(:millisecond) - started >= 50
    assert %{chat_id: @private, kind: :message, count: 1} = second
    assert second.at - first.at == 50

    assert {:error, {:rate_limited, wait}} =
             RateLimiter.acquire(@private, "private", :message, server: name, max_wait: 10)

    assert wait in 11..50
  end
end
