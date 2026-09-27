defmodule Angler.Storage.JanitorTest do
  # Replaces the application's janitor (a named process) and changes the app env.
  use Angler.DataCase, async: false

  import ExUnit.CaptureLog

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Settings
  alias Angler.Storage
  alias Angler.Storage.Janitor

  @never :timer.hours(1)
  @result %{purged: 1, freed_bytes: 2}

  setup do
    :ok = Supervisor.terminate_child(Angler.Supervisor, Janitor)
    on_exit(fn -> Supervisor.restart_child(Angler.Supervisor, Janitor) end)
  end

  describe "scheduling" do
    test "runs shortly after boot and then periodically" do
      start_janitor(initial_delay: 10, interval: 20)

      assert_receive :cleanup_ran
      assert_receive :cleanup_ran
      assert_receive :cleanup_ran
    end

    test "run_now/0 runs synchronously and returns the result" do
      start_janitor()

      assert Janitor.run_now() == @result
      assert_received :cleanup_ran
    end

    test "coalesces requests within the debounce window into one run" do
      start_janitor(debounce: 100)

      Janitor.schedule_run()
      Janitor.schedule_run()
      send(Janitor, :schedule_run)

      assert_receive :cleanup_ran, 1_000
      refute_receive :cleanup_ran, 300
    end

    test "runs again for requests made after a run" do
      start_janitor(debounce: 10)

      Janitor.schedule_run()
      assert_receive :cleanup_ran
      Janitor.schedule_run()
      assert_receive :cleanup_ran
    end

    test "runs when the settings change" do
      start_janitor(debounce: 10)

      {:ok, _setting} = Settings.update(%{"retention_hours" => "24"})

      assert_receive :cleanup_ran
    end

    test "a run satisfies pending requests" do
      start_janitor(debounce: 200)

      Janitor.schedule_run()
      assert Janitor.run_now() == @result
      assert_received :cleanup_ran

      refute_receive :cleanup_ran, 400
    end

    test "schedule_run/0 does nothing when the janitor is not running" do
      assert Process.whereis(Janitor) == nil
      assert Janitor.schedule_run() == :ok
    end

    test "ignores stale timers and unexpected messages" do
      pid = start_janitor()

      send(Janitor, {:timeout, make_ref(), :tick})
      send(Janitor, {:timeout, make_ref(), :debounced})
      send(Janitor, :unexpected)
      _ = :sys.get_state(Janitor)

      refute_received :cleanup_ran
      assert Process.whereis(Janitor) == pid
    end
  end

  describe "failures" do
    test "errors raised by a run are logged and don't stop the janitor" do
      pid =
        start_janitor(
          cleanup: fn -> raise File.Error, reason: :eacces, action: "remove", path: "/x" end
        )

      log = capture_log(fn -> assert Janitor.run_now() == %{purged: 0, freed_bytes: 0} end)

      assert log =~ "Storage cleanup failed"
      assert log =~ "permission denied"
      assert Process.whereis(Janitor) == pid
    end

    test "exits inside a run are caught too" do
      pid = start_janitor(cleanup: fn -> exit(:boom) end)

      assert capture_log(fn -> Janitor.run_now() end) =~ "Storage cleanup failed"
      assert Process.whereis(Janitor) == pid
    end
  end

  describe "configuration" do
    test "is not started when disabled" do
      assert Janitor.start_link(enabled: false) == :ignore

      config = Application.get_env(:angler, Janitor)
      Application.put_env(:angler, Janitor, enabled: false)
      on_exit(fn -> restore_env(Janitor, config) end)

      assert Janitor.start_link([]) == :ignore
    end
  end

  describe "with Angler.Storage" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      config = Application.fetch_env!(:angler, Angler.Media)
      Application.put_env(:angler, Angler.Media, Keyword.put(config, :data_dir, tmp_dir))
      on_exit(fn -> Application.put_env(:angler, Angler.Media, config) end)
    end

    test "run_now/0 enforces the storage limits" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "1"})
      expired = stored_entry(%{status: :done, finished_at: hours_ago(2)})
      start_supervised!({Janitor, enabled: true, initial_delay: @never, interval: @never})

      assert Janitor.run_now() == %{purged: 1, freed_bytes: expired.stored_bytes}
      assert Repo.get!(Entry, expired.id).storage_path == nil
    end

    test "run_now/0 cleans up in the caller when the janitor is disabled" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "1"})
      expired = stored_entry(%{status: :done, finished_at: hours_ago(2)})

      assert Process.whereis(Janitor) == nil
      assert Janitor.run_now() == %{purged: 1, freed_bytes: expired.stored_bytes}
    end

    test "finalizing an entry triggers a cleanup soon" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "1"})
      %Entry{id: expired_id} = stored_entry(%{status: :done, finished_at: hours_ago(2)})
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      File.write!(Storage.output_paths(dir).video, "video")

      start_supervised!(
        {Janitor, enabled: true, initial_delay: @never, interval: @never, debounce: 10}
      )

      Entries.subscribe()

      Storage.finalize(entry, [Storage.output_paths(dir).video])

      assert_receive {:entry_updated, %Entry{id: ^expired_id, storage_path: nil}}, 1_000
      # Let the run finish before the test (and its database connection) ends.
      _ = :sys.get_state(Janitor)
    end
  end

  defp start_janitor(opts \\ []) do
    test = self()

    cleanup = fn ->
      send(test, :cleanup_ran)
      @result
    end

    defaults = [
      enabled: true,
      cleanup: cleanup,
      initial_delay: @never,
      interval: @never,
      debounce: @never
    ]

    start_supervised!({Janitor, Keyword.merge(defaults, opts)})
  end

  defp entry_fixture do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: "https://example.com/v/#{n}", chat_id: 1, chat_type: "private", message_id: n}
      ])

    entry
  end

  defp stored_entry(attrs) do
    {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
    File.write!(Storage.output_paths(dir).video, "video bytes")

    entry
    |> Storage.record_usage()
    |> Entries.update!(attrs)
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

  defp restore_env(key, nil), do: Application.delete_env(:angler, key)
  defp restore_env(key, config), do: Application.put_env(:angler, key, config)
end
