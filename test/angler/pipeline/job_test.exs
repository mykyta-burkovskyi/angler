defmodule Angler.Pipeline.JobTest do
  use Angler.DataCase, async: true

  import Angler.TelegramFixtures
  import ExUnit.CaptureLog

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Pipeline.Job

  @timeout 2_000

  setup do
    :ok = Entries.subscribe()
    :ok
  end

  describe "throttled_progress/3" do
    test "broadcasts the first update right away and drops updates within the interval" do
      %Entry{id: id} = entry = claimed_entry()
      progress = Job.throttled_progress(entry, :downloading)

      assert progress.(%{percent: 12.5, detail: "1 MB of 8 MB"}) == :ok
      assert progress.(%{percent: 25.0, detail: "2 MB of 8 MB"}) == :ok

      assert_receive {:entry_progress, ^id,
                      %{stage: :downloading, percent: 12.5, detail: "1 MB of 8 MB"}},
                     @timeout

      refute_receive {:entry_progress, ^id, _progress}, 50
    end

    test "throttles calls from any process" do
      %Entry{id: id} = entry = claimed_entry()
      progress = Job.throttled_progress(entry, :processing)

      Task.await(Task.async(fn -> progress.(%{percent: 10.0, detail: nil}) end))
      progress.(%{percent: 20.0, detail: nil})

      assert_receive {:entry_progress, ^id, %{stage: :processing, percent: 10.0}}, @timeout
      refute_receive {:entry_progress, ^id, _progress}, 50
    end

    test "broadcasts again once the interval has passed" do
      %Entry{id: id} = entry = claimed_entry()
      progress = Job.throttled_progress(entry, :processing, interval: 0)

      progress.(%{percent: 10.0})
      progress.(%{detail: "Remuxing"})

      assert_receive {:entry_progress, ^id, %{percent: 10.0, detail: nil}}, @timeout
      assert_receive {:entry_progress, ^id, %{percent: nil, detail: "Remuxing"}}, @timeout
    end

    test "records heartbeats of the claimed entry while it reports progress" do
      entry = claimed_entry()
      silent_since = backdate(entry, -7 * 3600)

      # Not right away: the claim itself was a sign of life.
      Job.throttled_progress(entry, :processing).(%{percent: 1.0})
      assert Entries.get(entry.id).updated_at == silent_since

      progress = Job.throttled_progress(entry, :processing, heartbeat_interval: 0)
      progress.(%{percent: 2.0})
      assert DateTime.diff(DateTime.utc_now(), Entries.get(entry.id).updated_at) < 60

      # Heartbeats are not broadcast as changes.
      entry_id = entry.id
      refute_received {:entry_updated, %Entry{id: ^entry_id}}
    end

    test "never raises when the heartbeat can't be recorded" do
      entry = %Entry{id: "not-a-uuid", status: :processing, claimed_at: DateTime.utc_now()}
      progress = Job.throttled_progress(entry, :processing, heartbeat_interval: 0)

      log = capture_log(fn -> assert progress.(%{percent: 5.0}) == :ok end)
      assert log =~ "Could not record the heartbeat"
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
    flush_updates()
    entry
  end

  # Moves updated_at into the past (seconds); returns it.
  defp backdate(entry, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [updated_at: at])
    Entries.get(entry.id).updated_at
  end

  defp flush_updates do
    receive do
      {:entry_updated, _entry} -> flush_updates()
    after
      0 -> :ok
    end
  end
end
