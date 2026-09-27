defmodule AnglerWeb.EntriesLive.RowsTest do
  # The rows of the entries list (AnglerWeb.EntriesLive.Rows), through the page:
  # paging, and placing real-time updates.
  # Not async: the view subscribes to entry broadcasts, which other tests would send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AnglerWeb.EntriesLiveTestHelpers

  alias Angler.Entries

  setup %{conn: conn} do
    auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
    %{conn: put_req_header(conn, "authorization", auth)}
  end

  describe "pagination" do
    test "loads older entries page by page", %{conn: conn} do
      {:ok, entries} =
        Entries.enqueue(
          for n <- 1..55 do
            %{url: "https://x.com/u/status/#{n}", chat_id: 1, chat_type: "private", message_id: n}
          end
        )

      {:ok, view, _html} = live(conn, ~p"/")

      assert length(row_ids(view)) == 50
      assert has_element?(view, "#entries[phx-viewport-bottom]")
      refute has_element?(view, "#entries-end")

      view |> element("#load-more") |> render_click()

      ids = row_ids(view)
      assert length(ids) == 55
      assert Enum.sort(ids) == entries |> Enum.map(&dom_id/1) |> Enum.sort()
      assert has_element?(view, "#entries-end")
      refute has_element?(view, "#load-more")
      refute has_element?(view, "#entries[phx-viewport-bottom]")

      # A late viewport event has nothing left to load.
      render_hook(view, "load-more", %{})
      assert length(row_ids(view)) == 55
    end

    test "keeps the client list bounded without skipping entries", %{conn: conn} do
      {:ok, entries} =
        Entries.enqueue(
          for n <- 1..505 do
            %{url: "https://x.com/u/status/#{n}", chat_id: 1, chat_type: "private", message_id: n}
          end
        )

      {:ok, view, _html} = live(conn, ~p"/")
      for _page <- 2..10, do: render_hook(view, "load-more", %{})
      assert length(row_ids(view)) == 500

      new = entry_fixture()

      ids = row_ids(view)
      assert length(ids) == 500
      assert hd(ids) == dom_id(new)

      # The row pushed out at the bottom comes back with the next page.
      render_hook(view, "load-more", %{})

      all = [new | entries] |> Enum.map(&dom_id/1) |> Enum.sort()
      assert row_ids(view) |> Enum.sort() == all
      assert has_element?(view, "#entries-end")
    end

    test "loads the next rows once every row shown has left the filter", %{conn: conn} do
      {:ok, entries} =
        Entries.enqueue(
          for n <- 1..51 do
            %{url: "https://x.com/u/status/#{n}", chat_id: 1, chat_type: "private", message_id: n}
          end
        )

      for entry <- entries, do: Entries.mark_failed(entry, :internal, "boom")
      {:ok, view, _html} = live(conn, ~p"/?filter=failed")

      [oldest | shown] = Enum.reverse(Entries.list(filter: :failed, limit: 51))
      assert length(row_ids(view)) == 50
      refute dom_id(oldest) in row_ids(view)

      for entry <- shown, do: {:ok, _} = Entries.retry(entry)

      assert row_ids(view) == [dom_id(oldest)]
      assert has_element?(view, "#entries-end")

      # New failures show up again.
      failed = Entries.mark_failed(Entries.get!(hd(shown).id), :internal, "boom again")
      assert row_ids(view) == [dom_id(failed), dom_id(oldest)]
    end
  end

  describe "real-time updates" do
    test "inserts new entries at the top", %{conn: conn} do
      old = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      new = entry_fixture()

      assert row_ids(view) == [dom_id(new), dom_id(old)]
    end

    test "updates rows in place", %{conn: conn} do
      first = entry_fixture()
      second = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      Entries.update!(first, %{status: :downloading, attempts: 1})

      assert has_element?(view, "##{dom_id(first)} [data-status=downloading]")
      assert row_ids(view) == [dom_id(second), dom_id(first)]
    end

    test "removes rows that no longer match the filter", %{conn: conn} do
      entry = entry_fixture()
      {:ok, view, _html} = live(conn, ~p"/?filter=active")

      Entries.mark_done(entry)

      assert row_ids(view) == []
      assert has_element?(view, "#entries-empty", "Nothing in progress")
    end

    test "adds entries that start matching the filter at their position", %{conn: conn} do
      older = entry_fixture(%{status: :failed, error: "old failure"})
      entry = entry_fixture()
      newer = entry_fixture(%{status: :failed, error: "new failure"})
      {:ok, view, _html} = live(conn, ~p"/?filter=failed")

      assert row_ids(view) == [dom_id(newer), dom_id(older)]

      Entries.mark_failed(entry, :unsupported, "No video in this post")

      assert row_ids(view) == [dom_id(newer), dom_id(entry), dom_id(older)]
      assert has_element?(view, "##{dom_id(entry)}-error", "Unsupported link")
    end

    test "ignores entries outside the filter or search", %{conn: conn} do
      {:ok, filtered, _html} = live(conn, ~p"/?filter=failed")
      {:ok, searched, _html} = live(conn, ~p"/?q=youtube")

      entry_fixture()
      match = entry_fixture(%{url: "https://youtube.com/watch?v=1"})

      assert row_ids(filtered) == []
      assert row_ids(searched) == [dom_id(match)]
    end

    test "removes deleted entries", %{conn: conn} do
      entry = entry_fixture(%{status: :done})
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, _} = Entries.delete(entry)

      assert row_ids(view) == []
    end

    test "shows progress broadcasts of active entries", %{conn: conn} do
      entry = entry_fixture(%{status: :downloading, attempts: 1})
      {:ok, view, _html} = live(conn, ~p"/")

      Entries.broadcast_progress(entry.id, %{
        stage: :downloading,
        percent: 42.0,
        detail: "3.1MiB/s"
      })

      assert has_element?(view, "##{dom_id(entry)}-progress", "Downloading · 42% · 3.1MiB/s")
      assert has_element?(view, "##{dom_id(entry)} [role=progressbar][aria-valuenow='42']")

      # The next stage starts without the old percentage.
      Entries.advance(entry, :processing)

      assert has_element?(view, "##{dom_id(entry)}-progress", "Processing")
      refute has_element?(view, "##{dom_id(entry)}-progress", "42%")

      # Finished entries lose their progress bar.
      Entries.mark_done(Entries.get!(entry.id))
      refute has_element?(view, "##{dom_id(entry)}-progress")
    end

    test "ignores progress of entries that aren't shown", %{conn: conn} do
      entry = entry_fixture(%{status: :downloading})
      {:ok, view, _html} = live(conn, ~p"/?filter=failed")

      Entries.broadcast_progress(entry.id, %{stage: :downloading, percent: 10.0})

      assert row_ids(view) == []
    end
  end
end
