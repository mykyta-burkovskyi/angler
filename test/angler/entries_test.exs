defmodule Angler.EntriesTest do
  use Angler.DataCase, async: true

  import Angler.TelegramFixtures

  alias Angler.Entries
  alias Angler.Entries.{Entry, MediaItem}

  describe "update!/2" do
    test "changes a claimed entry while it is held by the same claim" do
      entry = claimed_entry()

      assert %Entry{status: :processing, title: "Fish"} =
               Entries.update!(entry, %{status: :processing, title: "Fish"})
    end

    test "refuses to change an entry in progress whose claim changed" do
      lost = claimed_entry()
      Entries.schedule_retry(lost, :internal, "Worker lost", 0)

      # Queued again: the worker that lost it can't move it back into progress.
      assert_raise Ecto.StaleEntryError, fn -> Entries.advance(lost, :processing) end
      assert %Entry{status: :queued} = Entries.get(lost.id)

      # Claimed by another worker: the first one can't finish it either.
      [reclaimed] = Entries.claim(1)
      assert_raise Ecto.StaleEntryError, fn -> Entries.mark_done(lost) end
      assert_raise Ecto.StaleEntryError, fn -> Entries.mark_failed(lost, :internal, "gone") end
      assert %Entry{status: :downloading} = Entries.get(lost.id)

      assert %Entry{status: :done} = Entries.mark_done(reclaimed)
    end

    test "changes entries that are not in progress without a claim check" do
      {:ok, [entry]} = enqueue()
      assert %Entry{title: "Queued"} = Entries.update!(entry, %{title: "Queued"})

      done = Entries.mark_done(claimed_entry())
      assert %Entry{telegram_file_id: nil} = Entries.update!(done, %{telegram_file_id: nil})
    end
  end

  describe "heartbeat/1" do
    test "touches the entry while its claim holds" do
      entry = claimed_entry()
      long_ago = DateTime.add(DateTime.utc_now(), -1, :hour)
      Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [updated_at: long_ago])

      assert Entries.heartbeat(entry)
      assert DateTime.diff(DateTime.utc_now(), Entries.get(entry.id).updated_at) < 60

      Entries.schedule_retry(entry, :internal, "Worker lost", 0)
      refute Entries.heartbeat(entry)
      refute Entries.heartbeat(%{entry | claimed_at: nil})
    end
  end

  describe "first_claim?/1" do
    test "tells the first claim from retries, recoveries and a re-queue from the dashboard" do
      first = claimed_entry()
      assert Entries.first_claim?(first)

      Entries.schedule_retry(first, :transient, "later", 0)
      [retried] = Entries.claim(1)
      refute Entries.first_claim?(retried)

      assert %{requeued: 1, failed: []} = Entries.recover_orphaned()
      [recovered] = Entries.claim(1)
      refute Entries.first_claim?(recovered)

      failed = Entries.mark_failed(recovered, :unavailable, "gone")
      {:ok, requeued} = Entries.retry(failed)
      assert requeued.started_at == nil
      [again] = Entries.claim(1)
      assert Entries.first_claim?(again)
    end
  end

  describe "retry/1" do
    test "forgets what an earlier delivery left, so an album is sent whole again" do
      items = [
        MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "AgAC1"}),
        MediaItem.new(%{type: :video, path: "album/02/video.mp4", file_id: "BAAC2"})
      ]

      done =
        Entries.mark_done(claimed_entry(), %{
          media_kind: :album,
          media_items: items,
          reply_message_id: 501
        })

      assert {:ok, %Entry{status: :queued, attempts: 0, media_kind: :album} = requeued} =
               Entries.retry(done)

      assert %Entry{media_items: [], reply_message_id: nil} = requeued
      assert %Entry{media_items: [], reply_message_id: nil} = Entries.get(done.id)
    end
  end

  describe "schedule_retry/5" do
    test "counts the attempt by default, or gives it back" do
      entry = claimed_entry()

      assert %Entry{status: :queued, attempts: 1} =
               Entries.schedule_retry(entry, :timeout, "x", 0)

      [entry] = Entries.claim(1)
      assert entry.attempts == 2

      assert %Entry{status: :queued, attempts: 1, error: "429"} =
               Entries.schedule_retry(entry, :transient, "429", 0, count_attempt: false)
    end
  end

  describe "mark_failed/4" do
    test "fails the entry, updating other fields in the same write" do
      entry = claimed_entry()
      items = [MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "FILE"})]

      assert %Entry{
               status: :failed,
               error_kind: :telegram,
               error: "Only 1 of 2 items were sent",
               claimed_at: nil,
               finished_at: %DateTime{},
               media_kind: :album,
               media_items: ^items
             } =
               Entries.mark_failed(entry, :telegram, "Only 1 of 2 items were sent", %{
                 media_kind: :album,
                 media_items: items
               })

      assert %Entry{status: :failed, media_kind: :album, media_items: ^items} =
               Entries.get(entry.id)
    end

    test "changes nothing else without attrs" do
      entry = Entries.update!(claimed_entry(), %{title: "Fish"})

      assert %Entry{status: :failed, error_kind: :unavailable, error: "gone", title: "Fish"} =
               Entries.mark_failed(entry, :unavailable, "gone")

      assert %Entry{media_items: []} = Entries.get(entry.id)
    end

    test "is refused once the entry's claim changed, like every update" do
      lost = claimed_entry()
      Entries.schedule_retry(lost, :internal, "Worker lost", 0)

      assert_raise Ecto.StaleEntryError, fn ->
        Entries.mark_failed(lost, :telegram, "partial", %{media_items: []})
      end
    end
  end

  describe "recover_orphaned/0" do
    test "queues entries in progress again and returns those failed for lack of attempts" do
      {:ok, _entries} = enqueue(max_attempts: 1)
      {:ok, _entries} = enqueue(max_attempts: 3)
      claimed = Entries.claim(2)
      {exhausted, _} = Enum.split_with(claimed, &(&1.max_attempts == 1))

      assert %{requeued: 1, failed: [failed], failed_uploads: []} = Entries.recover_orphaned()
      assert [failed.id] == Enum.map(exhausted, & &1.id)

      assert %Entry{
               status: :failed,
               error_kind: :internal,
               error: "Interrupted by a restart after the last attempt"
             } = failed
    end

    test "fails interrupted uploads with the given error when asked to" do
      {:ok, _entries} = enqueue(max_attempts: 1)
      {:ok, _entries} = enqueue(max_attempts: 3)
      {:ok, _entries} = enqueue(max_attempts: 3)
      [first, second, third] = Entries.claim(3)
      # Uploading on its last attempt, uploading, and downloading.
      Entries.update!(first, %{status: :uploading})
      Entries.update!(second, %{status: :uploading})

      assert %{requeued: 1, failed: [], failed_uploads: uploads} =
               Entries.recover_orphaned(fail_uploads: {:telegram, "may still appear"})

      assert Enum.sort(Enum.map(uploads, & &1.id)) == Enum.sort([first.id, second.id])

      for upload <- uploads do
        assert %Entry{
                 status: :failed,
                 error_kind: :telegram,
                 error: "may still appear",
                 claimed_at: nil,
                 finished_at: %DateTime{}
               } = upload
      end

      assert %Entry{status: :queued} = Entries.get(third.id)
    end
  end

  describe "stats/0" do
    test "counts entries as integers" do
      done = Entries.mark_done(claimed_entry(), %{output_bytes: 5})
      Entries.update!(done, %{stored_bytes: 7})

      assert %{total: 1, delivered_24h: 1, failed_24h: 0, by_status: %{done: 1}} =
               stats = Entries.stats()

      assert Map.keys(stats) |> Enum.sort() == [:by_status, :delivered_24h, :failed_24h, :total]
    end
  end

  defp enqueue(attrs \\ []) do
    Entries.enqueue([
      Map.merge(
        %{
          url: "https://fake.test/ok/#{unique_id()}",
          chat_id: unique_id(),
          chat_type: "private",
          message_id: unique_id()
        },
        Map.new(attrs)
      )
    ])
  end

  defp claimed_entry do
    {:ok, [_entry]} = enqueue()
    [entry] = Entries.claim(1)
    entry
  end
end
