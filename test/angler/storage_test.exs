defmodule Angler.StorageTest do
  # Changes the application env (data dir) and replaces the application's janitor.
  use Angler.DataCase, async: false

  import ExUnit.CaptureLog

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Settings
  alias Angler.Storage
  alias Angler.Storage.Janitor

  @moduletag :tmp_dir
  @mb 1_000_000
  @gb 1_000_000_000

  setup %{tmp_dir: tmp_dir} do
    config = Application.fetch_env!(:angler, Angler.Media)
    Application.put_env(:angler, Angler.Media, Keyword.put(config, :data_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:angler, Angler.Media, config) end)

    # The application's janitor would act on this test's data; some tests register
    # themselves under its name instead to observe `:schedule_run` requests.
    :ok = Supervisor.terminate_child(Angler.Supervisor, Janitor)
    on_exit(fn -> Supervisor.restart_child(Angler.Supervisor, Janitor) end)
  end

  describe "root/0 and output_paths/1" do
    test "keeps one directory per entry under <data_dir>/media", %{tmp_dir: tmp_dir} do
      assert Storage.root() == Path.join(tmp_dir, "media")

      assert Storage.output_paths("/data/media/abc") == %{
               video: "/data/media/abc/video.mp4",
               thumbnail: "/data/media/abc/thumbnail.jpg"
             }
    end
  end

  describe "managed_path?/1" do
    test "accepts only paths strictly inside the root", %{tmp_dir: tmp_dir} do
      root = Storage.root()

      assert Storage.managed_path?(Path.join(root, "abc/video.mp4"))
      refute Storage.managed_path?(root)
      refute Storage.managed_path?(root <> "-other/abc")
      refute Storage.managed_path?(Path.join(root, "../outside"))
      refute Storage.managed_path?(Path.join(tmp_dir, "outside"))
    end
  end

  describe "prepare_dir/1" do
    test "creates the entry directory and records it" do
      entry = entry_fixture()
      Entries.subscribe()

      assert {:ok, dir, updated} = Storage.prepare_dir(entry)

      assert dir == Path.join(Storage.root(), entry.id)
      assert File.dir?(dir)
      assert updated.storage_path == dir
      assert reload(entry).storage_path == dir
      assert_receive {:entry_updated, %Entry{storage_path: ^dir}}
    end

    test "empties a directory left over from a previous attempt" do
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      write_files(dir, %{"source.webm" => "partial", "frag/part-1" => "x"})

      entry =
        entry
        |> Storage.record_usage()
        |> Entries.update!(%{purged_at: DateTime.utc_now()})

      assert {:ok, ^dir, entry} = Storage.prepare_dir(entry)

      assert File.ls!(dir) == []
      assert %Entry{stored_bytes: 0, purged_at: nil} = entry
    end

    test "returns an error instead of raising on filesystem errors" do
      File.write!(Storage.root(), "not a directory")
      entry = entry_fixture()

      assert {:error, :enotdir} = Storage.prepare_dir(entry)
      assert reload(entry).storage_path == nil
    end

    test "refuses to start a download while free disk space stays below the floor after a cleanup",
         %{tmp_dir: tmp_dir} do
      kept = stored_entry(%{status: :done, finished_at: hours_ago(1), stored_bytes: 2 * @gb})
      # 1.5 GB free of 100 GB: below the floor of max(2 GB, 5%) = 5 GB, whatever is deleted.
      fake_df(tmp_dir, df_output(100 * @gb, 1_500_000_256))

      log =
        capture_log(fn ->
          assert {:error, :low_disk_space} = Storage.prepare_dir(entry_fixture())
        end)

      # The janitor ran first and evicted the kept video to make room.
      assert purged?(kept)
      assert log =~ "free disk space"
    end

    test "starts downloads when the free disk space is unknown", %{tmp_dir: tmp_dir} do
      fake_df(tmp_dir, "exit 1")

      assert {:ok, _dir, _entry} = Storage.prepare_dir(entry_fixture())
    end
  end

  describe "record_usage/1" do
    test "stores the size of every file in the entry directory" do
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      write_files(dir, %{"video.mp4" => "0123456789", "logs/pass.log" => "abcde"})

      assert Storage.record_usage(entry).stored_bytes == 15
      assert reload(entry).stored_bytes == 15
    end

    test "counts 0 bytes without a directory" do
      assert Storage.record_usage(entry_fixture()).stored_bytes == 0

      entry =
        entry_fixture(%{storage_path: Path.join(Storage.root(), "missing"), stored_bytes: 7})

      assert Storage.record_usage(entry).stored_bytes == 0
    end

    test "skips the write when nothing changed" do
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      write_files(dir, %{"video.mp4" => "123"})
      entry = Storage.record_usage(entry)
      Entries.subscribe()

      assert Storage.record_usage(entry) == entry
      refute_receive {:entry_updated, _entry}
    end
  end

  describe "finalize/2" do
    test "keeps the final files, deletes intermediates and asks the janitor for a run" do
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)

      write_files(dir, %{
        "video.mp4" => "final video",
        "thumbnail.jpg" => "jpeg",
        "source.webm" => "the original download",
        "ffmpeg2pass-0.log" => "stats",
        "fragments/part-1" => "partial"
      })

      Process.register(self(), Janitor)
      entry = Storage.finalize(entry, [video, thumbnail])

      assert Enum.sort(File.ls!(dir)) == ["thumbnail.jpg", "video.mp4"]
      assert entry.stored_bytes == byte_size("final video") + byte_size("jpeg")
      assert reload(entry).stored_bytes == entry.stored_bytes
      assert entry.storage_path == dir
      assert_receive :schedule_run
    end

    test "ignores a missing thumbnail and works when the janitor is not running" do
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      %{video: video} = Storage.output_paths(dir)
      write_files(dir, %{"video.mp4" => "final", "source.mkv" => "source"})

      entry = Storage.finalize(entry, [video, nil])

      assert File.ls!(dir) == ["video.mp4"]
      assert entry.stored_bytes == 5
    end

    test "leaves alone an entry that is being processed again since the caller read it" do
      {:ok, dir, stale} = Storage.prepare_dir(entry_fixture())
      write_files(dir, %{"video.mp4" => "final"})
      stale = Entries.mark_done(stale)

      {:ok, _requeued} = Entries.retry(stale)
      assert [claimed] = Entries.claim(1)
      {:ok, ^dir, _claimed} = Storage.prepare_dir(claimed)
      write_files(dir, %{"source.webm" => "downloading"})

      assert %Entry{status: :downloading} =
               Storage.finalize(stale, [Storage.output_paths(dir).video])

      assert File.read!(Path.join(dir, "source.webm")) == "downloading"
      assert reload(stale).stored_bytes == 0
    end

    test "purges right away when the retention period is 0" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "0"})
      {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
      %{video: video} = Storage.output_paths(dir)
      write_files(dir, %{"video.mp4" => "final"})

      entry = Storage.finalize(entry, [video])

      refute File.exists?(dir)
      assert %Entry{stored_bytes: 0, storage_path: nil, purged_at: %DateTime{}} = entry
      assert reload(entry).storage_path == nil
    end
  end

  describe "purge/1" do
    test "deletes the entry directory and marks the entry purged" do
      entry = stored_entry(%{status: :done})
      dir = entry.storage_path
      Entries.subscribe()

      purged = Storage.purge(entry)

      refute File.exists?(dir)
      assert %Entry{stored_bytes: 0, storage_path: nil, purged_at: %DateTime{}} = purged
      assert %Entry{storage_path: nil, stored_bytes: 0} = reload(entry)
      assert_receive {:entry_updated, %Entry{storage_path: nil}}
    end

    test "is idempotent" do
      purged = Storage.purge(stored_entry(%{status: :done}))
      without_files = entry_fixture()
      Entries.subscribe()

      assert Storage.purge(purged) == purged
      assert Storage.purge(without_files) == without_files
      refute_receive {:entry_updated, _entry}
    end

    test "removes a directory the entry never recorded" do
      entry = entry_fixture()
      dir = Path.join(Storage.root(), entry.id)
      write_files(dir, %{"source.mp4" => "x"})

      assert %Entry{purged_at: %DateTime{}} = Storage.purge(entry)
      refute File.exists?(dir)
    end

    test "never deletes anything outside the storage root", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "outside")
      write_files(outside, %{"video.mp4" => "keep me"})
      entry = entry_fixture(%{status: :done, storage_path: outside, stored_bytes: 7})

      log = capture_log(fn -> assert Storage.purge(entry).storage_path == nil end)

      assert log =~ "outside of the storage root"
      assert File.read!(Path.join(outside, "video.mp4")) == "keep me"
    end

    test "leaves alone an entry that is being processed again since the caller read it" do
      stale = stored_entry(%{status: :done, finished_at: DateTime.utc_now()})

      # Re-queued from the dashboard, claimed, and its directory prepared again.
      {:ok, _requeued} = Entries.retry(stale)
      assert [%Entry{status: :downloading} = claimed] = Entries.claim(1)
      {:ok, dir, _claimed} = Storage.prepare_dir(claimed)
      write_files(dir, %{"source.webm" => "downloading"})
      Entries.subscribe()

      assert %Entry{status: :downloading, storage_path: ^dir} = Storage.purge(stale)

      assert File.read!(Path.join(dir, "source.webm")) == "downloading"
      assert %Entry{status: :downloading, storage_path: ^dir} = reload(stale)
      refute_receive {:entry_updated, _entry}
    end

    test "does not raise for an entry deleted since the caller read it" do
      entry = stored_entry(%{status: :done})
      {:ok, _deleted} = Entries.delete(entry)

      assert Storage.purge(entry) == entry
    end
  end

  describe "video_path/1 and thumbnail_path/1" do
    test "return the final files while they exist" do
      entry = stored_entry(%{status: :done})
      %{video: video, thumbnail: thumbnail} = Storage.output_paths(entry.storage_path)

      assert Storage.video_path(entry) == video
      assert Storage.thumbnail_path(entry) == thumbnail

      File.rm!(thumbnail)
      assert Storage.thumbnail_path(entry) == nil
    end

    test "return nil for an entry without files" do
      entry = entry_fixture()

      assert Storage.video_path(entry) == nil
      assert Storage.thumbnail_path(entry) == nil
    end
  end

  describe "usage/0" do
    test "sums the stored bytes and reports the limit and disk space" do
      {:ok, _setting} = Settings.update(%{"storage_limit_mb" => "500"})
      stored_entry(%{status: :done, stored_bytes: 1_500})
      stored_entry(%{status: :failed, stored_bytes: 500})
      entry_fixture()

      assert %{
               used_bytes: 2_000,
               limit_bytes: 500_000_000,
               entries_with_files: 2,
               disk_total_bytes: total,
               disk_free_bytes: free
             } = Storage.usage()

      assert is_integer(total) and total > 0
      assert is_integer(free) and free >= 0 and free <= total
    end

    test "works before the storage root exists" do
      refute File.exists?(Storage.root())

      assert %{used_bytes: 0, entries_with_files: 0, disk_total_bytes: total} = Storage.usage()
      assert is_integer(total)
    end

    test "counts only finished entries as kept, work in progress separately" do
      stored_entry(%{status: :done, stored_bytes: 1_500})
      stored_entry(%{status: :processing, stored_bytes: 700})
      stored_entry(%{status: :queued, stored_bytes: 300})

      assert %{used_bytes: 1_500, entries_with_files: 1, in_progress_bytes: 1_000} =
               Storage.usage()
    end

    test "stops a hanging df and reports unknown disk space", %{tmp_dir: tmp_dir} do
      # Long enough for the script to record its pid before it is killed.
      put_storage_config(df_timeout: 1_000)
      stored_entry(%{status: :done, stored_bytes: 1_500})
      pid_file = Path.join(tmp_dir, "df.pid")
      # Like a stale network mount; and like the release image, without a kill(1) binary.
      fake_df(tmp_dir, "echo $$ > #{pid_file}\nexec /bin/sleep 30", path: :replace)

      assert %{used_bytes: 1_500, disk_total_bytes: nil, disk_free_bytes: nil} = Storage.usage()

      os_pid = pid_file |> File.read!() |> String.trim()
      on_exit(fn -> signal_os_process(os_pid, "KILL") end)
      refute signal_os_process(os_pid, "0"), "the hanging df is still running"
    end
  end

  describe "enforce_limits/0 retention" do
    test "purges finished entries older than the retention period" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "24"})

      expired = stored_entry(%{status: :done, finished_at: hours_ago(25)})
      failed = stored_entry(%{status: :failed, finished_at: hours_ago(48)})
      recent = stored_entry(%{status: :done, finished_at: hours_ago(23)})
      queued = stored_entry(%{status: :queued, finished_at: hours_ago(48)})
      active = stored_entry(%{status: :processing, finished_at: hours_ago(48)})

      assert Storage.enforce_limits() == %{
               purged: 2,
               freed_bytes: expired.stored_bytes + failed.stored_bytes
             }

      assert purged?(expired)
      assert purged?(failed)
      refute purged?(recent)
      refute purged?(queued)
      refute purged?(active)
    end

    test "purges every finished entry when the retention period is 0" do
      {:ok, _setting} = Settings.update(%{"retention_hours" => "0"})

      done = stored_entry(%{status: :done, finished_at: DateTime.utc_now()})
      cancelled = stored_entry(%{status: :cancelled})
      active = stored_entry(%{status: :uploading})

      assert %{purged: 2} = Storage.enforce_limits()
      assert purged?(done)
      assert purged?(cancelled)
      refute purged?(active)
    end

    test "does nothing when there is nothing to clean up" do
      stored_entry(%{status: :done, finished_at: DateTime.utc_now()})

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
    end
  end

  describe "enforce_limits/0 size cap" do
    setup do
      {:ok, _setting} = Settings.update(%{"storage_limit_mb" => "100"})
      :ok
    end

    test "evicts the oldest finished entries until usage is under the limit" do
      oldest = stored_entry(%{status: :done, finished_at: hours_ago(4), stored_bytes: 40 * @mb})
      older = stored_entry(%{status: :failed, finished_at: hours_ago(3), stored_bytes: 40 * @mb})

      newer =
        stored_entry(%{status: :cancelled, finished_at: hours_ago(2), stored_bytes: 40 * @mb})

      newest = stored_entry(%{status: :done, finished_at: hours_ago(1), stored_bytes: 40 * @mb})
      active = stored_entry(%{status: :downloading, stored_bytes: 40 * @mb})

      assert Storage.enforce_limits() == %{purged: 2, freed_bytes: 80 * @mb}

      assert purged?(oldest)
      assert purged?(older)
      refute purged?(newer)
      refute purged?(newest)
      refute purged?(active)
      assert Storage.usage().used_bytes == 80 * @mb
    end

    test "never evicts queued or active entries" do
      queued = stored_entry(%{status: :queued, stored_bytes: 60 * @mb})
      active = stored_entry(%{status: :processing, stored_bytes: 60 * @mb})

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
      refute purged?(queued)
      refute purged?(active)
    end

    test "applies to the kept files of finished entries, not to work in progress" do
      kept = stored_entry(%{status: :done, finished_at: hours_ago(1), stored_bytes: 50 * @mb})
      stored_entry(%{status: :downloading, stored_bytes: 60 * @mb})
      stored_entry(%{status: :queued, stored_bytes: 30 * @mb})

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
      refute purged?(kept)
    end
  end

  describe "enforce_limits/0 free disk space" do
    test "evicts the oldest finished entries until the free space floor is reached",
         %{tmp_dir: tmp_dir} do
      oldest = stored_entry(%{status: :done, finished_at: hours_ago(4), stored_bytes: 2 * @gb})
      older = stored_entry(%{status: :failed, finished_at: hours_ago(3), stored_bytes: 2 * @gb})
      newer = stored_entry(%{status: :done, finished_at: hours_ago(2), stored_bytes: 2 * @gb})
      newest = stored_entry(%{status: :done, finished_at: hours_ago(1), stored_bytes: 2 * @gb})
      queued = stored_entry(%{status: :queued, stored_bytes: 2 * @gb})
      active = stored_entry(%{status: :downloading, stored_bytes: 2 * @gb})
      # 1.5 GB free of 100 GB, the floor is max(2 GB, 5%) = 5 GB: 3.5 GB must go.
      fake_df(tmp_dir, df_output(100 * @gb, 1_500_000_256))

      assert %{purged: 2, freed_bytes: freed} =
               capture_log_result(fn -> Storage.enforce_limits() end)

      assert freed == 4 * @gb
      assert purged?(oldest)
      assert purged?(older)
      refute purged?(newer)
      refute purged?(newest)
      refute purged?(queued)
      refute purged?(active)
    end

    test "does nothing while there is enough free space", %{tmp_dir: tmp_dir} do
      kept = stored_entry(%{status: :done, finished_at: hours_ago(1), stored_bytes: 2 * @gb})
      fake_df(tmp_dir, df_output(100 * @gb, 6 * @gb))

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
      refute purged?(kept)
    end
  end

  describe "enforce_limits/0 entry history" do
    setup do
      {:ok, _setting} =
        Settings.update(%{"history_days" => "30", "retention_hours" => "#{24 * 365}"})

      :ok
    end

    test "deletes finished entries older than the history period, and their files first" do
      old_done = entry_fixture(%{status: :done, finished_at: days_ago(31)})
      old_failed = stored_entry(%{status: :failed, finished_at: days_ago(40)})
      recent = stored_entry(%{status: :done, finished_at: days_ago(29)})
      queued = entry_fixture(%{status: :queued, finished_at: days_ago(40)})
      active = stored_entry(%{status: :processing, finished_at: days_ago(40)})
      Entries.subscribe()

      assert %{purged: 1} = Storage.enforce_limits()

      refute Repo.get(Entry, old_done.id)
      refute Repo.get(Entry, old_failed.id)
      refute File.exists?(old_failed.storage_path)
      assert_receive {:entry_deleted, id} when id == old_done.id
      assert_receive {:entry_deleted, id} when id == old_failed.id

      refute purged?(recent)
      assert Repo.get(Entry, queued.id)
      refute purged?(active)
    end

    test "keeps every entry when the history period is 0" do
      {:ok, _setting} = Settings.update(%{"history_days" => "0"})
      old = entry_fixture(%{status: :done, finished_at: days_ago(3650)})

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
      assert Repo.get(Entry, old.id)
    end
  end

  describe "enforce_limits/0 reconciliation" do
    test "removes stale directories no entry records" do
      recorded = stored_entry(%{status: :done, finished_at: DateTime.utc_now()})
      unrecorded = entry_fixture(%{status: :failed})

      leftover = Path.join(Storage.root(), "leftover")
      of_unrecorded = Path.join(Storage.root(), unrecorded.id)
      fresh = Path.join(Storage.root(), "being-claimed")
      write_files(leftover, %{"source.mp4" => "0123456789"})
      write_files(of_unrecorded, %{"part" => "01234"})
      write_files(fresh, %{"source.mp4" => "x"})
      File.write!(Path.join(Storage.root(), "stray-file"), "x")
      Enum.each([leftover, of_unrecorded, recorded.storage_path], &age/1)

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 15}

      refute File.exists?(leftover)
      refute File.exists?(of_unrecorded)
      assert File.dir?(fresh)
      assert File.dir?(recorded.storage_path)
      assert File.exists?(Path.join(Storage.root(), "stray-file"))
    end

    test "forgets directories that disappeared, except for entries in progress" do
      done = stored_entry(%{status: :done, finished_at: DateTime.utc_now()})
      active = stored_entry(%{status: :processing})
      File.rm_rf!(done.storage_path)
      File.rm_rf!(active.storage_path)

      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}

      assert %Entry{stored_bytes: 0, storage_path: nil, purged_at: %DateTime{}} = reload(done)
      assert reload(active).storage_path == active.storage_path
    end

    test "copes with a missing storage root" do
      refute File.exists?(Storage.root())
      assert Storage.enforce_limits() == %{purged: 0, freed_bytes: 0}
    end
  end

  defp entry_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: "https://example.com/v/#{n}", chat_id: 1, chat_type: "private", message_id: n}
      ])

    if attrs == %{}, do: entry, else: Entries.update!(entry, attrs)
  end

  # An entry whose directory holds a final video and thumbnail.
  defp stored_entry(attrs) do
    {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
    write_files(dir, %{"video.mp4" => "video bytes", "thumbnail.jpg" => "jpeg"})

    entry
    |> Storage.record_usage()
    |> Entries.update!(attrs)
  end

  defp write_files(dir, files) do
    for {name, content} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
  end

  # Makes a directory look older than the orphan grace period.
  defp age(dir), do: File.touch!(dir, System.os_time(:second) - 3600)

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)
  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp put_storage_config(config) do
    previous = Application.get_env(:angler, Storage)
    Application.put_env(:angler, Storage, Keyword.merge(previous || [], config))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:angler, Storage, previous),
        else: Application.delete_env(:angler, Storage)
    end)
  end

  # Puts a `df` running `script` first in PATH (`path: :replace` makes it the only
  # directory in PATH) and uses the default free space floor.
  defp fake_df(tmp_dir, script, opts \\ []) do
    put_storage_config(min_free_bytes: 2 * @gb, min_free_percent: 5)

    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "df"), "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(Path.join(bin, "df"), 0o755)

    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    case Keyword.get(opts, :path, :prepend) do
      :prepend -> System.put_env("PATH", bin <> ":" <> path)
      :replace -> System.put_env("PATH", bin)
    end
  end

  # A script printing POSIX `df -Pk` output for a filesystem of this size.
  defp df_output(total_bytes, free_bytes) do
    total = div(total_bytes, 1024)
    free = div(free_bytes, 1024)

    """
    cat <<'EOF'
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/fake #{total} #{total - free} #{free} 99% /data
    EOF
    """
  end

  # Whether `kill -s <signal>` succeeded; signal "0" only checks the process exists.
  defp signal_os_process(os_pid, signal) do
    {_output, status} =
      System.cmd("/bin/sh", ["-c", ~s(kill -s "$1" "$2" 2>/dev/null), "sh", signal, os_pid])

    status == 0
  end

  defp capture_log_result(fun) do
    {result, _log} = with_log(fun)
    result
  end

  defp reload(%Entry{id: id}), do: Repo.get!(Entry, id)

  defp purged?(%Entry{} = entry) do
    %Entry{storage_path: path, stored_bytes: bytes, purged_at: purged_at} = reload(entry)

    cond do
      is_nil(path) and bytes == 0 and not is_nil(purged_at) ->
        refute File.exists?(entry.storage_path)
        true

      File.dir?(path) ->
        false
    end
  end
end
