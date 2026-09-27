defmodule Angler.Pipeline.FailuresTest do
  # Not async: failure feedback goes through the application's global rate limiter,
  # and background retries run under the application's task supervisor.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures
  import ExUnit.CaptureLog

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{Failures, RetryPolicy}
  alias Broadway.Message

  @moduletag :capture_log
  @timeout 2_000

  setup do
    stub_bot_api()
    :ok = Entries.subscribe()
    :ok
  end

  test "schedules a retry with the context's base delay" do
    entry = claimed_entry("private")
    failed = Message.failed(message(entry), {:timeout, "took too long"})

    assert Failures.handle(failed, %{retry_base_delay: 60_000}) == :ok

    assert %Entry{status: :queued, attempts: 1, error_kind: :timeout, error: "took too long"} =
             retried = Entries.get(entry.id)

    assert DateTime.diff(retried.available_at, DateTime.utc_now(), :millisecond) in 47_000..72_000
  end

  test "postpones failures that say when to try again, giving the attempt back" do
    entry = claimed_entry("private")
    failed = Message.failed(message(entry), {:transient, "Too Many Requests", 20})

    Failures.handle(failed, %{retry_base_delay: 10})

    assert %Entry{status: :queued, attempts: 0, error: "Too Many Requests"} =
             postponed = Entries.get(entry.id)

    assert DateTime.diff(postponed.available_at, DateTime.utc_now()) in 18..20
  end

  test "postpones even on the last attempt" do
    entry = claimed_entry("private", max_attempts: 1)
    assert entry.attempts == 1
    failed = Message.failed(message(entry), {:transient, "cached file rejected", 0})

    Failures.handle(failed, %{})

    assert %Entry{status: :queued, attempts: 0} = Entries.get(entry.id)
  end

  test "postpones entries while disk space is low, however long ago they were first claimed" do
    entry = claimed_entry("private", max_attempts: 1)
    long_ago = DateTime.add(DateTime.utc_now(), -2, :day)
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [started_at: long_ago])
    failed = Message.failed(message(entry), RetryPolicy.storage_failure(:low_disk_space))

    Failures.handle(failed, %{})

    assert %Entry{status: :queued, attempts: 0, error: "Not enough free disk space"} =
             postponed = Entries.get(entry.id)

    assert DateTime.diff(postponed.available_at, DateTime.utc_now()) in 298..300
  end

  test "fails permanent errors and sends feedback" do
    entry = claimed_entry("private")
    failed = Message.failed(message(entry), {:unavailable, "Private video"})

    assert Failures.handle(failed, %{}) == :ok

    assert %Entry{status: :failed, error_kind: :unavailable, error: "Private video"} =
             Entries.get(entry.id)

    message_id = entry.message_id

    assert_receive {:bot_api, "setMessageReaction",
                    %{"message_id" => ^message_id, "reaction" => [%{"emoji" => "👎"}]}},
                   @timeout

    assert_receive {:bot_api, "sendMessage",
                    %{"text" => "This video is private, removed or unavailable."}},
                   @timeout
  end

  test "accepts upload messages from the batcher" do
    entry = claimed_entry("supergroup")
    data = %{entry: entry, video: {:file_id, "F"}, output: nil, settings: nil}
    failed = Message.failed(message(data), {:telegram, "Forbidden"})

    Failures.handle(failed, %{})

    assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)
    assert_receive {:bot_api, "setMessageReaction", _params}, @timeout
  end

  test "classifies crashes as internal errors" do
    entry = claimed_entry("private")
    crashed = %{message(entry) | status: {:error, %RuntimeError{message: "boom"}, []}}

    Failures.handle(crashed, %{retry_base_delay: 10})

    assert %Entry{status: :queued, error_kind: :internal, error: "** (RuntimeError) boom"} =
             Entries.get(entry.id)
  end

  test "leaves entries alone that are no longer in progress" do
    {:ok, [entry]} = enqueue("private")
    failed = Message.failed(message(entry), {:transient, "late failure"})

    Failures.handle(failed, %{})

    assert %Entry{status: :queued, error: nil} = Entries.get(entry.id)
  end

  test "leaves entries alone that were claimed again since" do
    lost = claimed_entry("private")

    # The stale check gave the entry to another worker meanwhile.
    Entries.schedule_retry(lost, :internal, "Worker lost", 0)
    [reclaimed] = Entries.claim(1)
    assert reclaimed.id == lost.id

    Failures.handle(Message.failed(message(lost), {:internal, "files vanished"}), %{})

    assert %Entry{status: :downloading, error: "Worker lost", claimed_at: claimed_at} =
             Entries.get(lost.id)

    assert claimed_at == reclaimed.claimed_at
  end

  test "ignores entries that no longer exist" do
    entry = %Entry{id: Ecto.UUID.generate()}
    assert Failures.handle(Message.failed(message(entry), {:transient, "gone"}), %{}) == :ok
  end

  test "handles the failure in the background while the database can't be reached" do
    entry = claimed_entry("private")
    fail_updates_to("queued", 2)
    failed = Message.failed(message(entry), {:transient, "network hiccup"})

    log =
      capture_log(fn ->
        assert Failures.handle(failed, %{retry_base_delay: 10, db_retry_delays: [10, 10, 10]}) ==
                 :ok
      end)

    assert log =~ "trying again in the background"

    entry_id = entry.id

    assert_receive {:entry_updated,
                    %Entry{id: ^entry_id, status: :queued, error: "network hiccup"}},
                   @timeout
  end

  test "never raises" do
    log =
      capture_log(fn ->
        assert Failures.handle(Message.failed(message(:garbage), {:internal, "x"}), %{}) == :ok
      end)

    assert log =~ "Could not handle a failed entry"
  end

  defp message(data), do: %Message{data: data, acknowledger: Broadway.NoopAcknowledger.init()}

  defp enqueue(chat_type, attrs \\ %{}) do
    chat_id = if chat_type == "private", do: unique_id(), else: -unique_id()

    Entries.enqueue([
      Map.merge(
        %{
          url: "https://fake.test/ok/#{unique_id()}",
          chat_id: chat_id,
          chat_type: chat_type,
          message_id: unique_id()
        },
        Map.new(attrs)
      )
    ])
  end

  defp claimed_entry(chat_type, attrs \\ %{}) do
    {:ok, [_entry]} = enqueue(chat_type, attrs)
    [entry] = Entries.claim(1)
    entry
  end

  # The next `count` updates that set `status` fail like a database outage would
  # (rolled back with the test's transaction).
  defp fail_updates_to(status, count) do
    for sql <- [
          "CREATE SEQUENCE test_outage",
          """
          CREATE FUNCTION test_outage() RETURNS trigger AS $$
          BEGIN
            IF NEW.status = '#{status}' AND nextval('test_outage') <= #{count} THEN
              RAISE EXCEPTION 'simulated database outage';
            END IF;
            RETURN NEW;
          END $$ LANGUAGE plpgsql
          """,
          "CREATE TRIGGER test_outage BEFORE UPDATE ON entries " <>
            "FOR EACH ROW EXECUTE FUNCTION test_outage()"
        ] do
      Repo.query!(sql)
    end
  end
end
