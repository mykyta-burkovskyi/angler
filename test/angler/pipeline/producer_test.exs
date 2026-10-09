defmodule Angler.Pipeline.ProducerTest do
  use Angler.DataCase, async: true

  import Angler.TelegramFixtures

  alias Angler.Entries
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Pipeline.Producer
  alias Broadway.Message

  # Long enough that no poll fires during a test unless it is sent explicitly.
  @no_poll 60_000
  # Feedback goes through the application's global rate limiter.
  @timeout 2_000

  describe "demand" do
    test "claims only as many due entries as demanded" do
      [first, second, third] = enqueue(3)
      state = init()

      assert {:noreply, messages, state} = Producer.handle_demand(2, state)
      assert Enum.sort(ids(messages)) == [first.id, second.id]
      assert state.pending_demand == 0
      assert Enum.all?(messages, &(&1.data.status == :downloading and &1.data.attempts == 1))
      assert Entries.get(third.id).status == :queued

      # Without demand, notifications and polls don't claim anything.
      assert {:noreply, [], state} = Producer.handle_info(:entries_queued, state)
      assert {:noreply, [], state} = Producer.handle_info(:poll, state)
      assert Entries.get(third.id).status == :queued

      assert {:noreply, [message], state} = Producer.handle_demand(5, state)
      assert message.data.id == third.id
      assert state.pending_demand == 4
    end

    test "wraps entries into messages with a no-op acknowledger" do
      [entry] = enqueue(1)

      assert {:noreply, [%Message{} = message], _state} = Producer.handle_demand(1, init())
      assert %Entry{id: id, status: :downloading} = message.data
      assert id == entry.id
      assert message.acknowledger == Broadway.NoopAcknowledger.init()
    end

    test "keeps unmet demand and serves it when entries are queued" do
      state = init()
      assert {:noreply, [], state} = Producer.handle_demand(2, state)
      assert state.pending_demand == 2

      [entry] = enqueue(1)
      assert_receive :entries_queued

      assert {:noreply, [message], state} = Producer.handle_info(:entries_queued, state)
      assert message.data.id == entry.id
      assert state.pending_demand == 1
    end

    test "claims due entries on a poll and schedules the next one" do
      state = init()
      assert {:noreply, [], state} = Producer.handle_demand(1, state)
      [entry] = enqueue(1)

      assert {:noreply, [message], state} = Producer.handle_info(:poll, state)
      assert message.data.id == entry.id
      assert is_reference(state.poll_timer)
    end

    test "leaves entries alone until their available_at" do
      # The oldest entry is claimed and scheduled for a retry in a minute.
      [_oldest, due] = enqueue(2)
      [delayed] = Entries.claim(1)
      Entries.schedule_retry(delayed, :transient, "try later", 60_000)

      assert {:noreply, [message], state} = Producer.handle_demand(2, init())
      assert message.data.id == due.id
      assert state.pending_demand == 1
      assert %Entry{status: :queued} = Entries.get(delayed.id)

      # Due retries are picked up by the next poll.
      Entries.schedule_retry(Entries.get(delayed.id), :transient, "now", 0)
      assert {:noreply, [message], _state} = Producer.handle_info(:poll, state)
      assert message.data.id == delayed.id
    end

    test "ignores unrelated messages" do
      state = init()
      assert Producer.handle_info(:unexpected, state) == {:noreply, [], state}
    end
  end

  describe "prepare_for_draining/1" do
    test "stops claiming and polling" do
      [entry] = enqueue(1)
      state = init()

      assert {:noreply, [], state} = Producer.prepare_for_draining(state)
      assert state.poll_timer == nil

      assert {:noreply, [], state} = Producer.handle_demand(3, state)
      assert {:noreply, [], state} = Producer.handle_info(:entries_queued, state)
      assert {:noreply, [], state} = Producer.handle_info(:poll, state)
      assert state.poll_timer == nil
      assert Entries.get(entry.id).status == :queued
    end
  end

  describe "recover_stale/1" do
    setup do
      stub_bot_api()
      :ok
    end

    test "queues entries silent for too long again, or fails them without attempts left" do
      [stale, exhausted, fresh] = enqueue(3)
      Entries.claim(3)
      Entries.update!(Entries.get!(stale.id), %{status: :processing})
      Entries.update!(Entries.get!(exhausted.id), %{attempts: 3})
      silence([stale, exhausted], -7)

      assert Producer.recover_stale(:timer.hours(6)) == {1, 1}

      assert %Entry{status: :queued, error_kind: :internal, error: "Worker lost"} =
               Entries.get(stale.id)

      assert %Entry{status: :failed, error_kind: :internal, error: "Worker lost"} =
               Entries.get(exhausted.id)

      assert %Entry{status: :downloading} = Entries.get(fresh.id)

      # The failed entry gets the usual failure feedback.
      exhausted_message_id = exhausted.message_id

      assert_receive {:bot_api, "setMessageReaction",
                      %{"message_id" => ^exhausted_message_id, "reaction" => [%{"emoji" => "🤷"}]}},
                     @timeout

      assert_receive {:bot_api, "sendMessage",
                      %{"reply_parameters" => %{"message_id" => ^exhausted_message_id}}},
                     @timeout
    end

    @tag :capture_log
    test "fails an album of which a part was delivered as sent in part" do
      [album] = enqueue(1)
      [claimed] = Entries.claim(1)

      items = [
        MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "AgAC1"}),
        MediaItem.new(%{type: :photo, path: "album/02/photo.jpg"})
      ]

      Entries.update!(claimed, %{
        status: :uploading,
        attempts: 3,
        media_kind: :album,
        media_items: items
      })

      silence([album], -7)

      assert Producer.recover_stale(:timer.hours(6)) == {0, 1}

      assert %Entry{status: :failed, error_kind: :telegram, error: error} = Entries.get(album.id)
      assert error == "Only 1 of 2 items were sent: the upload was interrupted"

      assert_receive {:bot_api, "sendMessage", %{"text" => "Only 1 of 2 items could be sent."}},
                     @timeout
    end

    test "leaves long-running entries alone while their worker shows signs of life" do
      [changed, beating] = enqueue(2)
      [changed_claim, beating_claim] = Enum.sort_by(Entries.claim(2), & &1.id)
      long_ago = DateTime.add(DateTime.utc_now(), -7, :hour)

      # Claimed 7 hours ago; since then one moved to the next stage and one had a
      # heartbeat (e.g. from the progress of a long conversion).
      Repo.update_all(from(e in Entry, where: e.id in ^[changed.id, beating.id]),
        set: [claimed_at: long_ago, started_at: long_ago, updated_at: long_ago]
      )

      Entries.advance(%{changed_claim | claimed_at: long_ago}, :processing)
      assert Entries.heartbeat(%{beating_claim | claimed_at: long_ago})

      assert Producer.recover_stale(:timer.hours(6)) == {0, 0}
      assert %Entry{status: :processing} = Entries.get(changed.id)
      assert %Entry{status: :downloading} = Entries.get(beating.id)
    end

    @tag :capture_log
    test "runs on the first poll, then at most once per check interval" do
      [first, second] = enqueue(2)
      Entries.claim(2)
      silence([first], -7)

      state = init(stale_after: :timer.hours(6), stale_check_interval: :timer.minutes(5))
      assert {:noreply, [], state} = Producer.handle_info(:poll, state)
      assert Entries.get(first.id).status == :queued

      silence([second], -7)
      assert {:noreply, [], _state} = Producer.handle_info(:poll, state)
      assert Entries.get(second.id).status == :downloading
    end
  end

  describe "as a GenStage producer" do
    test "emits claimed entries to a subscribed consumer when work is queued" do
      producer =
        start_supervised!(%{
          id: Producer,
          start: {GenStage, :start_link, [Producer, [poll_interval: @no_poll]]}
        })

      Ecto.Adapters.SQL.Sandbox.allow(Angler.Repo, self(), producer)

      consumer =
        Task.async(fn -> [{producer, max_demand: 1}] |> GenStage.stream() |> Enum.take(2) end)

      [first] = enqueue(1)
      [second] = enqueue(1)

      assert [%Message{data: %Entry{} = claimed_first}, %Message{data: %Entry{} = claimed_second}] =
               Task.await(consumer)

      assert [claimed_first.id, claimed_second.id] == [first.id, second.id]
      assert Entries.get(first.id).status == :downloading
      assert Entries.get(second.id).status == :downloading
    end
  end

  defp init(opts \\ []) do
    assert {:producer, state} = Producer.init(Keyword.put_new(opts, :poll_interval, @no_poll))
    state
  end

  defp enqueue(count) do
    chat_id = unique_id()

    {:ok, entries} =
      1..count
      |> Enum.map(fn n ->
        %{
          url: "https://fake.test/ok/#{unique_id()}",
          chat_id: chat_id,
          chat_type: "private",
          message_id: n
        }
      end)
      |> Entries.enqueue()

    # Entries of one insert share available_at; claims order them by id.
    Enum.sort_by(entries, & &1.id)
  end

  defp ids(messages), do: Enum.map(messages, & &1.data.id)

  # No sign of life from the entries' workers since `hours` (negative) from now.
  defp silence(entries, hours) do
    at = DateTime.add(DateTime.utc_now(), hours, :hour)
    ids = Enum.map(entries, & &1.id)
    Repo.update_all(from(e in Entry, where: e.id in ^ids), set: [updated_at: at])
  end
end
