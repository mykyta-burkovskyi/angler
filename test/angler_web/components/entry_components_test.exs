defmodule AnglerWeb.EntryComponentsTest do
  use ExUnit.Case, async: true

  import AnglerWeb.ComponentTestHelpers
  import AnglerWeb.EntryComponents

  alias Angler.Entries.MediaItem

  describe "entry_row/1" do
    test "links the title to the entry and describes where it came from" do
      entry =
        entry(title: "A funny cat", output_bytes: 12_345_678, duration: 65.0, transcoded: true)

      html = render_html(&entry_row/1, id: "entry-#{entry.id}", entry: entry)

      assert attribute(html, "a", "href") == "/entries/#{entry.id}"
      assert text(html, "a") =~ "A funny cat"
      row = text(html, "li")
      assert row =~ "tiktok.com"
      assert row =~ "Video club"
      assert row =~ "by Ann"
      assert row =~ "12.3 MB"
      assert row =~ "1:05"
      assert exists?(html, "[data-role=transcoded]")
      assert exists?(html, "time[phx-hook]")
    end

    test "falls back to the link as title and hides the sender of private chats" do
      entry = entry(chat_type: "private", chat_title: nil, from_name: "Bob")
      html = render_html(&entry_row/1, id: "row", entry: entry)

      assert text(html, "a") =~ entry.url
      refute text(html, "li") =~ "by Bob"
      assert text(html, "li") =~ "Bob"
    end

    test "shows the thumbnail when there is one, else a platform tile" do
      entry = entry(status: :done)

      with_thumbnail = render_html(&entry_row/1, id: "row", entry: entry, thumbnail_url: "/t.jpg")
      assert attribute(with_thumbnail, "img", "src") == "/t.jpg"

      without = render_html(&entry_row/1, id: "row", entry: entry)
      refute exists?(without, "img")
      assert text(without, "div[title=TikTok]") =~ "TT"
    end

    test "shows live progress of active entries" do
      entry = entry(status: :downloading)
      progress = %{stage: :downloading, percent: 42.0, detail: "3.1MiB/s, ETA 00:12"}
      html = render_html(&entry_row/1, id: "row", entry: entry, progress: progress)

      assert text(html, "#row-progress") =~ "Downloading · 42% · 3.1MiB/s, ETA 00:12"
      assert attribute(html, "[role=progressbar]", "aria-valuenow") == "42"
    end

    test "ignores progress of a previous stage" do
      entry = entry(status: :processing, stage_detail: "Re-encoding")
      progress = %{stage: :downloading, percent: 99.0, detail: "almost"}
      html = render_html(&entry_row/1, id: "row", entry: entry, progress: progress)

      assert text(html, "#row-progress") =~ "Processing · Re-encoding"
      refute text(html, "#row-progress") =~ "99%"
    end

    test "shows why an entry failed" do
      entry = entry(status: :failed, error_kind: :unavailable, error: "This video is private")
      html = render_html(&entry_row/1, id: "row", entry: entry)

      assert text(html, "#row-error") =~ "Unavailable: This video is private"
    end

    test "notes a pending retry" do
      entry = entry(status: :queued, error: "Connection reset", attempts: 1, max_attempts: 3)
      html = render_html(&entry_row/1, id: "row", entry: entry)

      assert text(html, "#row-retry-note") =~ "Attempt 1 of 3 failed"
    end

    test "offers the actions allowed by the status" do
      actions = fn status ->
        html = render_html(&entry_row/1, id: "row", entry: entry(status: status))
        for action <- ~w(retry cancel delete), exists?(html, "#row-#{action}"), do: action
      end

      assert actions.(:queued) == ~w(cancel delete)
      assert actions.(:downloading) == []
      assert actions.(:done) == ~w(retry delete)
      assert actions.(:failed) == ~w(retry delete)
      assert actions.(:cancelled) == ~w(retry delete)
    end

    test "confirms destructive actions" do
      html = render_html(&entry_row/1, id: "row", entry: entry(status: :done))

      assert attribute(html, "#row-delete", "data-confirm") =~ "Delete"
      assert attribute(html, "#row-retry", "aria-label") == "Send again"
      assert attribute(html, "#row-retry", "data-confirm") =~ "again"

      failed = render_html(&entry_row/1, id: "row", entry: entry(status: :failed))
      assert attribute(failed, "#row-retry", "data-confirm") == nil
      assert attribute(failed, "#row-retry", "phx-value-id") =~ ~r/^[0-9a-f-]{36}$/
    end
  end

  describe "retry_confirm/1" do
    test "asks before a delivered entry is sent again" do
      assert retry_confirm(entry(status: :done)) == "Download and send this to the chat again?"
      assert retry_confirm(entry(status: :done, media_kind: :slideshow)) =~ "this to the chat"

      assert retry_confirm(entry(status: :done, media_kind: :album, media_items: items(3))) ==
               "Download and send all 3 items of this album to the chat again?"

      assert retry_confirm(entry(status: :done, media_kind: :album)) =~ "this whole album"

      assert retry_confirm(entry(status: :done, media_kind: :album, media_items: items(1))) ==
               "Download and send this photo to the chat again?"
    end

    test "asks before an album is sent again after some of it was sent" do
      [sent, _unsent, _other] = items = items(3)
      items = [%{sent | file_id: "photo-file"} | tl(items)]

      assert retry_confirm(entry(status: :failed, media_kind: :album, media_items: items)) ==
               "1 of 3 items were already sent. Send the whole album again?"

      assert retry_confirm(entry(status: :cancelled, media_kind: :album, media_items: items)) =~
               "already sent"
    end

    test "doesn't ask when nothing was sent" do
      assert retry_confirm(entry(status: :failed)) == nil

      assert retry_confirm(entry(status: :failed, media_kind: :album, media_items: items(2))) ==
               nil

      assert retry_confirm(entry(status: :queued)) == nil
    end

    test "is what the row's Send again button asks" do
      entry = entry(status: :done, media_kind: :album, media_items: items(2))
      html = render_html(&entry_row/1, id: "row", entry: entry)

      assert attribute(html, "#row-retry", "data-confirm") =~ "all 2 items of this album"
    end
  end

  test "album_kind/1" do
    assert album_kind(entry(media_kind: :album, media_items: items(2))) == "album"
    assert album_kind(entry(media_kind: :album, media_items: items(1))) == "photo"
    assert album_kind(entry(media_kind: :album)) == "album"
    assert album_kind(entry(media_kind: :video)) == nil
    assert album_kind(entry()) == nil
  end

  test "entry_host/1 and entry_title/1" do
    assert entry_host(entry(source_host: "www.YouTube.com")) == "youtube.com"
    assert entry_host(entry(source_host: nil, url: "https://youtu.be/x")) == "youtu.be"
    assert entry_title(entry(title: "")) == entry().url
  end

  defp items(count) do
    for n <- 1..count//1, do: MediaItem.new(%{type: :photo, path: "album/0#{n}/photo.jpg"})
  end
end
