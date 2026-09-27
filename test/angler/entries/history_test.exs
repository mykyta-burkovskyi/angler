defmodule Angler.Entries.HistoryTest do
  use Angler.DataCase, async: true

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Entries.History

  describe "prune/2" do
    test "deletes finished entries that finished before the cutoff and announces it" do
      done = entry_fixture(%{status: :done, finished_at: days_ago(10)})
      failed = entry_fixture(%{status: :failed, finished_at: days_ago(20)})
      cancelled = entry_fixture(%{status: :cancelled, finished_at: days_ago(8)})
      recent = entry_fixture(%{status: :done, finished_at: days_ago(6)})
      Entries.subscribe()

      assert History.prune(days_ago(7)) == 3

      assert remaining() == [recent.id]
      for %Entry{id: id} <- [done, failed, cancelled], do: assert_receive({:entry_deleted, ^id})
      refute_receive {:entry_deleted, _id}
    end

    test "keeps entries that are not finished or still hold files" do
      queued = entry_fixture(%{status: :queued, finished_at: days_ago(10)})
      active = entry_fixture(%{status: :processing, finished_at: days_ago(10)})

      with_files =
        entry_fixture(%{status: :done, finished_at: days_ago(10), storage_path: "/data/media/x"})

      with_bytes = entry_fixture(%{status: :failed, finished_at: days_ago(10), stored_bytes: 5})

      assert History.prune(days_ago(7)) == 0

      assert Enum.sort(remaining()) ==
               Enum.sort([queued.id, active.id, with_files.id, with_bytes.id])
    end

    test "deletes in batches" do
      for _ <- 1..5, do: entry_fixture(%{status: :done, finished_at: days_ago(10)})

      assert History.prune(days_ago(7), batch_size: 2) == 5
      assert remaining() == []
    end
  end

  defp entry_fixture(attrs) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: "https://example.com/v/#{n}", chat_id: 1, chat_type: "private", message_id: n}
      ])

    Entries.update!(entry, attrs)
  end

  defp remaining, do: Repo.all(from e in Entry, select: e.id)

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)
end
