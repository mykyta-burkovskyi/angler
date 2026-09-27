defmodule AnglerWeb.EntriesLiveTest do
  # Paging and real-time updates of the list are tested in entries_live/rows_test.exs.
  # Not async: the view subscribes to entry broadcasts, which other tests would send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AnglerWeb.EntriesLiveTestHelpers

  alias Angler.{Entries, Settings}

  setup %{conn: conn} do
    auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
    %{conn: put_req_header(conn, "authorization", auth)}
  end

  defp stat(view, id), do: view |> element("##{id} [data-role=value]") |> render() |> text()

  defp tab_count(view, filter),
    do: view |> element("#filter-#{filter} [data-role=count]") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp stats_timer(view) do
    %{socket: %{assigns: %{stats_timer: timer}}} = :sys.get_state(view.pid)
    timer
  end

  # Reports to the test whether `id` is listed in each render of the view.
  def report_listed(_event, _measurements, %{socket: socket}, {view_pid, test_pid, id}) do
    if self() == view_pid,
      do: send(test_pid, {:listed?, List.keymember?(socket.assigns.rows, id, 1)})
  end

  defp track_listed(view, entry) do
    handler = {__MODULE__, :listed, entry.id}

    :telemetry.attach(
      handler,
      [:phoenix, :live_view, :render, :start],
      &__MODULE__.report_listed/4,
      {view.pid, self(), entry.id}
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp listed_in_renders do
    receive do
      {:listed?, listed?} -> [listed? | listed_in_renders()]
    after
      0 -> []
    end
  end

  describe "rendering" do
    test "shows stats, storage and entries in every status", %{conn: conn} do
      now = DateTime.utc_now()
      queued = entry_fixture()
      downloading = entry_fixture(%{status: :downloading, attempts: 1})

      done =
        entry_fixture(%{status: :done, title: "A funny cat", finished_at: now, transcoded: true})

      failed =
        entry_fixture(%{
          status: :failed,
          error_kind: :unavailable,
          error: "This video is private",
          finished_at: now
        })

      cancelled = entry_fixture(%{status: :cancelled, finished_at: now})

      {:ok, view, _html} = live(conn, ~p"/")

      assert page_title(view) =~ "Entries"
      assert has_element?(view, "#live-indicator")
      assert has_element?(view, "#storage-meter")

      assert stat(view, "stat-queued") == "1"
      assert stat(view, "stat-active") == "1"
      assert stat(view, "stat-delivered") == "1"
      assert stat(view, "stat-failed") == "1"

      assert tab_count(view, :all) == "5"
      assert tab_count(view, :active) == "2"
      assert tab_count(view, :done) == "1"
      assert tab_count(view, :failed) == "1"
      assert tab_count(view, :cancelled) == "1"

      assert row_ids(view) == Enum.map([cancelled, failed, done, downloading, queued], &dom_id/1)

      for entry <- [queued, downloading, done, failed, cancelled] do
        assert has_element?(view, "##{dom_id(entry)} [data-status=#{entry.status}]")
      end

      assert has_element?(view, "##{dom_id(done)} a[href='/entries/#{done.id}']", "A funny cat")
      assert has_element?(view, "##{dom_id(done)} [data-role=transcoded]")
      assert has_element?(view, "##{dom_id(failed)}-error", "This video is private")
      assert has_element?(view, "##{dom_id(downloading)}-progress")
    end

    test "shows an empty state without entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#entries-empty", "No entries yet")
      refute has_element?(view, "#entries-end")
    end

    test "links each row to its entry page", %{conn: conn} do
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: path}}} =
               view |> element("##{dom_id(entry)} a") |> render_click()

      assert path == ~p"/entries/#{entry.id}"
    end
  end

  describe "filters and search" do
    test "filter tabs patch the URL and narrow the list", %{conn: conn} do
      queued = entry_fixture()
      failed = entry_fixture(%{status: :failed, error: "boom", error_kind: :internal})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#filter-failed") |> render_click()
      assert_patch(view, ~p"/?filter=failed")

      assert row_ids(view) == [dom_id(failed)]
      assert has_element?(view, "#filter-failed[aria-current=page]")

      view |> element("#filter-active") |> render_click()
      assert_patch(view, ~p"/?filter=active")
      assert row_ids(view) == [dom_id(queued)]
    end

    test "reads the filter and search from the URL", %{conn: conn} do
      _other = entry_fixture(%{status: :done})
      match = entry_fixture(%{status: :done, title: "Cats compilation"})
      _queued_cat = entry_fixture(%{title: "More cats"})

      {:ok, view, _html} = live(conn, ~p"/?filter=done&q=cats")

      assert row_ids(view) == [dom_id(match)]
      assert has_element?(view, "#search-input[value=cats]")
    end

    test "falls back to all entries for an unknown filter", %{conn: conn} do
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/?filter=nope")

      assert row_ids(view) == [dom_id(entry)]
      assert has_element?(view, "#filter-all[aria-current=page]")
    end

    test "search narrows the list and keeps the filter", %{conn: conn} do
      dogs = entry_fixture(%{title: "Dogs"})
      cats = entry_fixture(%{title: "Funny Cats"})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#search-form", q: "  cat ") |> render_change()
      assert_patch(view, ~p"/?q=cat")
      assert row_ids(view) == [dom_id(cats)]

      view |> element("#filter-active") |> render_click()
      assert_patch(view, ~p"/?filter=active&q=cat")

      view |> form("#search-form", q: "") |> render_submit()
      assert_patch(view, ~p"/?filter=active")
      assert row_ids(view) == [dom_id(cats), dom_id(dogs)]
    end

    test "explains when nothing matches", %{conn: conn} do
      entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/?q=zebra")

      assert has_element?(view, "#entries-empty", "No entries match “zebra”")

      view |> element("#entries-empty a", "Clear search") |> render_click()
      assert_patch(view, ~p"/")
      assert length(row_ids(view)) == 1
    end
  end

  describe "stats" do
    test "refreshes stats at most once per interval", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert stat(view, "stat-queued") == "0"

      entry_fixture()
      timer = stats_timer(view)
      assert Process.read_timer(timer) <= 1_000

      entry_fixture()
      assert stats_timer(view) == timer

      send(view.pid, :refresh_stats)

      assert stat(view, "stat-queued") == "2"
      assert tab_count(view, :all) == "2"
    end

    test "refreshes stats periodically and when the settings change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Without any event, "in the last 24 hours" still moves on.
      timer = stats_timer(view)
      assert is_reference(timer)
      assert Process.read_timer(timer) > 1_000

      {:ok, _} = Settings.update(%{"storage_limit_mb" => "50000"})

      timer = stats_timer(view)
      assert Process.read_timer(timer) <= 1_000

      send(view.pid, :refresh_stats)

      assert view |> element("#storage-meter [data-role=limit]") |> render() |> text() == "50 GB"
      assert Process.read_timer(stats_timer(view)) > 1_000
    end
  end

  describe "row actions" do
    test "retries a failed entry", %{conn: conn} do
      entry = entry_fixture(%{status: :failed, error: "boom", error_kind: :internal})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("##{dom_id(entry)}-retry") |> render_click()

      assert has_element?(view, "#flash-info", "Queued again.")
      assert has_element?(view, "##{dom_id(entry)} [data-status=queued]")
      assert Entries.get(entry.id).status == :queued
    end

    test "cancels a queued entry", %{conn: conn} do
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("##{dom_id(entry)}-cancel") |> render_click()

      assert has_element?(view, "#flash-info", "Entry cancelled.")
      assert has_element?(view, "##{dom_id(entry)} [data-status=cancelled]")
    end

    test "deletes finished and queued entries", %{conn: conn} do
      done = entry_fixture(%{status: :done})
      queued = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("##{dom_id(done)}-delete") |> render_click()
      assert has_element?(view, "#flash-info", "Entry deleted.")

      view |> element("##{dom_id(queued)}-delete") |> render_click()

      assert row_ids(view) == []
      assert Entries.get(done.id) == nil
      assert Entries.get(queued.id) == nil
    end

    test "does not show a deleted row again before it's gone", %{conn: conn} do
      # Deleting a queued entry cancels it first, which is broadcast too.
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")
      track_listed(view, entry)

      view |> element("##{dom_id(entry)}-delete") |> render_click()
      assert row_ids(view) == []

      # Once the row is gone, it stays gone.
      assert [false | _] = renders = Enum.drop_while(listed_in_renders(), & &1)
      refute true in renders
    end

    test "does not offer deleting active entries", %{conn: conn} do
      entry = entry_fixture(%{status: :uploading})
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "##{dom_id(entry)}-delete")

      render_click(view, "delete", %{"id" => entry.id})

      assert has_element?(view, "#flash-error", "being processed")
      assert Entries.get(entry.id)
    end

    test "reports actions that are no longer possible", %{conn: conn} do
      queued = entry_fixture()
      done = entry_fixture(%{status: :done})
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "retry", %{"id" => queued.id})
      assert has_element?(view, "#flash-error", "Only finished entries can be retried.")

      render_click(view, "cancel", %{"id" => done.id})
      assert has_element?(view, "#flash-error", "Only queued entries can be cancelled.")

      render_click(view, "retry", %{"id" => Ecto.UUID.generate()})
      assert has_element?(view, "#flash-error", "This entry no longer exists.")
    end
  end
end
