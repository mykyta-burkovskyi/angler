defmodule AnglerWeb.EntryLiveTest do
  # Not async: the view subscribes to entry broadcasts, which other tests would send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Entries

  setup %{conn: conn} do
    auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
    %{conn: put_req_header(conn, "authorization", auth)}
  end

  defp entry_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{
          url: "https://www.youtube.com/watch?v=#{n}",
          source_host: "youtube.com",
          chat_id: -1_001_234,
          chat_type: "supergroup",
          chat_title: "Video club",
          message_id: n,
          message_thread_id: 3,
          from_id: 42,
          from_name: "Ann"
        }
      ])

    if attrs == %{}, do: entry, else: Entries.update!(entry, attrs)
  end

  defp delivered_attrs do
    started = DateTime.add(DateTime.utc_now(), -95)

    %{
      status: :done,
      title: "Cats compilation",
      extractor: "youtube",
      duration: 65.4,
      width: 1080,
      height: 1920,
      video_codec: "h264",
      source_bytes: 84_100_000,
      output_bytes: 48_900_000,
      transcoded: true,
      reused_file_id: false,
      telegram_file_id: "BAACAgIAAxkBAAIBQ2abcdefghijklmnopqrstuvwxyz0123456789",
      reply_message_id: 777,
      storage_path: "/data/media/abc",
      stored_bytes: 49_000_000,
      attempts: 1,
      started_at: started,
      finished_at: DateTime.add(started, 34)
    }
  end

  # Delivers the entry right after the connected page read it, as the pipeline may.
  def finish_after_read(_event, _measurements, %{source: "entries"}, config) do
    %{entry: entry, test_pid: test_pid, once: once} = config

    if self() != test_pid and Process.get(:"$initial_call") == {AnglerWeb.EntryLive, :mount, 3} and
         :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      Entries.mark_done(entry)
    end
  end

  def finish_after_read(_event, _measurements, _metadata, _config), do: :ok

  describe "rendering" do
    test "shows everything about a delivered entry", %{conn: conn} do
      entry = entry_fixture(delivered_attrs())
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      assert page_title(view) =~ "Cats compilation"
      assert has_element?(view, "#entry-title", "Cats compilation")
      assert has_element?(view, "#entry-status[data-status=done]")

      assert has_element?(
               view,
               "#entry-url[href='#{entry.url}'][target=_blank][rel='noopener noreferrer']"
             )

      assert has_element?(view, "#source-panel", "YouTube")
      assert has_element?(view, "#source-panel", "youtube")

      assert has_element?(view, "#media-panel", "1:05")
      assert has_element?(view, "#media-panel", "1080×1920")
      assert has_element?(view, "#media-panel", "h264")
      assert has_element?(view, "#media-panel", "84.1 MB → 48.9 MB")

      assert has_element?(view, "#telegram-panel", "Video club")
      assert has_element?(view, "#telegram-panel", "supergroup")
      assert has_element?(view, "#telegram-panel", "Ann (42)")
      assert has_element?(view, "#telegram-panel", "in thread 3")
      assert has_element?(view, "#telegram-panel", "#777")
      assert has_element?(view, "#entry-file-id", "BAACAgIAAxkBAAIBQ2abcde…")

      assert has_element?(view, "#processing-panel", "1 of 3")
      assert has_element?(view, "#processing-panel", "34s")
      assert has_element?(view, "#storage-panel", "/data/media/abc")
      assert has_element?(view, "#storage-panel", "49 MB")

      assert has_element?(view, "#entry-stages li[data-state=complete]")
      refute has_element?(view, "#entry-stages li[data-state=pending]")

      # Nothing on disk in tests.
      assert has_element?(view, "#no-preview")
      refute has_element?(view, "#entry-video")

      assert has_element?(view, "#retry-entry[data-confirm]", "Send again")
      assert has_element?(view, "#purge-entry")
      assert has_element?(view, "#delete-entry")
      refute has_element?(view, "#cancel-entry")
    end

    test "shows the full error of a failed entry", %{conn: conn} do
      error = "ERROR: [Instagram] abc: Requested content is not available\nrate-limit reached"

      entry =
        entry_fixture(%{status: :failed, error_kind: :unavailable, error: error, attempts: 3})

      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      assert has_element?(view, "#entry-error", "Unavailable")
      assert has_element?(view, "#entry-error", "Failed after 3 of 3 attempts")

      assert view |> element("#entry-error-text") |> render() =~
               "not available\nrate-limit reached"

      refute has_element?(view, "#entry-stages")
      assert has_element?(view, "#retry-entry", "Retry")
      refute has_element?(view, "#retry-entry[data-confirm]")
    end

    test "shows a pending retry of a queued entry", %{conn: conn} do
      entry = entry_fixture(%{attempts: 1})
      entry = Entries.schedule_retry(entry, :transient, "Connection reset by peer", 60_000)

      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      assert has_element?(view, "#entry-retry", "Attempt 1 of 3 failed")
      assert has_element?(view, "#entry-retry", "Temporary error")
      assert has_element?(view, "#entry-error-text", "Connection reset by peer")
      assert has_element?(view, "#entry-stages li[data-state=current]", "Queued")
      assert has_element?(view, "#cancel-entry")
    end

    test "shows a cancelled entry", %{conn: conn} do
      entry = entry_fixture(%{status: :cancelled, finished_at: DateTime.utc_now()})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      assert has_element?(view, "#entry-cancelled", "Cancelled")
      assert has_element?(view, "#no-preview", "Nothing was stored")
    end

    test "wraps a long chat title instead of widening the page", %{conn: conn} do
      title = "Смешные_видео_и_мемы_для_всей_семьи_2026"
      entry = entry_fixture(%{chat_title: title})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      # Flex items don't shrink below their longest word unless it may break.
      assert has_element?(view, "#entry-meta[class*='[overflow-wrap:anywhere]']", title)
    end

    test "shows a not found state for unknown ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entries/#{Ecto.UUID.generate()}")
      assert has_element?(view, "#entry-not-found")
      assert page_title(view) =~ "Entry not found"

      {:ok, view, _html} = live(conn, ~p"/entries/not-a-uuid")
      assert has_element?(view, "#entry-not-found")

      # Actions do nothing without an entry.
      render_click(view, "delete", %{})
      assert has_element?(view, "#entry-not-found")
    end
  end

  describe "real-time updates" do
    test "follows changes and progress of the entry", %{conn: conn} do
      entry = entry_fixture()
      other = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      entry =
        Entries.update!(entry, %{status: :downloading, attempts: 1, title: "Now with a title"})

      assert has_element?(view, "#entry-title", "Now with a title")
      assert has_element?(view, "#entry-stages li[data-state=current]", "Downloading")
      refute has_element?(view, "#delete-entry")

      Entries.broadcast_progress(entry.id, %{
        stage: :downloading,
        percent: 42.0,
        detail: "ETA 00:12"
      })

      Entries.broadcast_progress(other.id, %{stage: :downloading, percent: 99.0})
      Entries.update!(other, %{title: "Another entry"})

      assert has_element?(view, "#entry-progress-bar", "Downloading · 42% · ETA 00:12")
      refute has_element?(view, "#entry-title", "Another entry")

      Entries.advance(entry, :processing, %{stage_detail: "Re-encoding"})

      assert has_element?(view, "#entry-progress-bar", "Processing · Re-encoding")
      refute has_element?(view, "#entry-progress-bar", "42%")
    end

    test "shows a change made while the page loads", %{conn: conn} do
      entry = entry_fixture(%{status: :uploading, attempts: 1})
      handler = {__MODULE__, :finish_after_read}

      :telemetry.attach(handler, [:angler, :repo, :query], &__MODULE__.finish_after_read/4, %{
        entry: entry,
        test_pid: self(),
        once: :atomics.new(1, [])
      })

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      assert Entries.get(entry.id).status == :done
      assert has_element?(view, "#entry-status[data-status=done]")
    end

    test "leaves when the entry is deleted elsewhere", %{conn: conn} do
      entry = entry_fixture(%{status: :failed, error: "boom"})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")
      # The view navigates away on its own; don't let its shutdown take the test down.
      Process.flag(:trap_exit, true)

      {:ok, _} = Entries.delete(entry)

      assert assert_redirect(view, ~p"/") == %{"info" => "The entry was deleted."}
    end
  end

  describe "actions" do
    test "retries a failed entry", %{conn: conn} do
      entry = entry_fixture(%{status: :failed, error: "boom", error_kind: :internal})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      view |> element("#retry-entry") |> render_click()

      assert has_element?(view, "#flash-info", "Queued again.")
      assert has_element?(view, "#entry-status[data-status=queued]")
    end

    test "cancels a queued entry", %{conn: conn} do
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      view |> element("#cancel-entry") |> render_click()

      assert has_element?(view, "#flash-info", "Entry cancelled.")
      assert has_element?(view, "#entry-status[data-status=cancelled]")
    end

    test "deletes the stored files", %{conn: conn} do
      entry = entry_fixture(delivered_attrs())
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      view |> element("#purge-entry") |> render_click()

      assert has_element?(view, "#flash-info", "Files deleted.")
      assert Entries.get(entry.id)
    end

    test "keeps the files of a queued entry", %{conn: conn} do
      # Sent again: the files of the delivery stay until a worker claims the entry.
      entry = entry_fixture(%{status: :done, stored_bytes: 1_000})
      {:ok, entry} = Entries.retry(entry)
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      refute has_element?(view, "#purge-entry")

      render_click(view, "purge", %{})

      assert has_element?(view, "#flash-error", "while the entry is queued")
      assert Entries.get(entry.id).stored_bytes == 1_000
    end

    test "deletes the entry and returns to the list", %{conn: conn} do
      entry = entry_fixture(%{status: :done})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      {:ok, list, _html} =
        view
        |> element("#delete-entry")
        |> render_click()
        |> follow_redirect(conn, ~p"/")

      assert has_element?(list, "#flash-info", "Entry deleted.")
      assert Entries.get(entry.id) == nil
    end

    test "refuses to touch an entry that became active", %{conn: conn} do
      entry = entry_fixture(%{status: :done, stored_bytes: 1_000})
      {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

      # Re-queued and claimed elsewhere, while this page still shows it as done.
      {:ok, entry} = Entries.retry(entry)

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.entry, %{entry | status: :done})
      end)

      [_claimed] = Entries.claim(1)

      render_click(view, "purge", %{})
      assert has_element?(view, "#flash-error", "being processed")

      render_click(view, "delete", %{})
      assert has_element?(view, "#flash-error", "being processed")
      assert Entries.get(entry.id)
    end
  end
end
