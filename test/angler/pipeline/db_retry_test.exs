defmodule Angler.Pipeline.DbRetryTest do
  use Angler.DataCase, async: true

  import Angler.TelegramFixtures

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Pipeline.DbRetry

  describe "run/2" do
    test "runs the function again while the database can't be reached" do
      calls = :counters.new(1, [])

      fun = fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) < 3, do: raise(DBConnection.ConnectionError, "gone")
        :done
      end

      assert DbRetry.run(fun, [0, 0, 0]) == {:ok, :done}
      assert :counters.get(calls, 1) == 3
    end

    test "returns the last database error once the delays are used up" do
      fun = fn -> raise DBConnection.ConnectionError, "gone" end
      assert {:error, %DBConnection.ConnectionError{message: "gone"}} = DbRetry.run(fun, [0])
    end

    test "raises other exceptions" do
      assert_raise RuntimeError, fn -> DbRetry.run(fn -> raise "bug" end, [0]) end
    end
  end

  describe "record/4" do
    test "treats a write that was committed although its reply was lost as recorded" do
      entry = claimed_entry()
      calls = :counters.new(1, [])

      # The first write is committed, then the connection breaks before the reply.
      mark_done = fn entry ->
        :counters.add(calls, 1, 1)
        done = Entries.mark_done(entry, %{reply_message_id: 7})
        if :counters.get(calls, 1) == 1, do: raise(DBConnection.ConnectionError, "gone")
        done
      end

      recorded? = &(&1.status == :done and &1.reply_message_id == 7)

      assert {:ok, %Entry{status: :done, reply_message_id: 7}} =
               DbRetry.record(entry, mark_done, recorded?, [0])

      assert :counters.get(calls, 1) == 2
    end

    test "reports an entry another worker took over" do
      lost = claimed_entry()
      Entries.schedule_retry(lost, :internal, "Worker lost", 0)
      [_reclaimed] = Entries.claim(1)

      assert DbRetry.record(lost, &Entries.mark_done/1, &(&1.status == :done), [0]) ==
               {:error, :taken_over}

      assert %Entry{status: :downloading} = Entries.get(lost.id)
    end

    test "returns the database error once the delays are used up" do
      fun = fn _entry -> raise DBConnection.ConnectionError, "gone" end

      assert {:error, %DBConnection.ConnectionError{}} =
               DbRetry.record(claimed_entry(), fun, fn _entry -> true end, [0])
    end
  end

  defp claimed_entry do
    {:ok, [_entry]} =
      Entries.enqueue([
        %{
          url: "https://fake.test/ok/#{unique_id()}",
          chat_id: unique_id(),
          chat_type: "private",
          message_id: unique_id()
        }
      ])

    [entry] = Entries.claim(1)
    entry
  end
end
