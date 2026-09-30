defmodule AnglerWeb.EntryLiveAlbumTest do
  # The entry page of an album: its gallery, post text, media and Telegram details.
  # Not async: the view subscribes to entry broadcasts, which other tests would send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AnglerWeb.EntriesLiveTestHelpers, only: [album_fixture: 0, album_fixture: 1]

  alias Angler.Entries
  alias Angler.Entries.MediaItem
  alias Angler.Storage

  setup %{conn: conn} do
    auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
    %{conn: put_req_header(conn, "authorization", auth)}
  end

  test "shows the photos and videos of a delivered album", %{conn: conn} do
    entry = album_fixture()
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-album[data-count='2']")
    photo = "/media/#{entry.id}/items/0"
    video = "/media/#{entry.id}/items/1"

    assert has_element?(
             view,
             "#entry-media-0[data-type=photo] a[href='#{photo}'][target=_blank][rel='noopener noreferrer'] img[src='#{photo}'][loading=lazy]"
           )

    assert has_element?(
             view,
             "#entry-media-1[data-type=video] video[src='#{video}'][poster='#{video}/thumbnail'][controls][preload=metadata]"
           )

    assert has_element?(view, "#entry-media-1 a[href='#{video}'][target=_blank]")
    refute has_element?(view, "#entry-video")
    refute has_element?(view, "#no-preview")

    # The page links only to files the dashboard serves.
    for url <- [photo, video, video <> "/thumbnail", "/media/#{entry.id}/thumbnail"] do
      assert conn |> get(url) |> response(200)
    end
  end

  test "shows the post text in full and clamps the heading", %{conn: conn} do
    entry = album_fixture()
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    # Exactly the text: its line breaks are kept, and nothing is added around it.
    assert view |> element("#entry-post-text") |> render() =~
             ~r"^<pre[^>]*>Sunset at the lake\n\nMore photos soon #summer</pre>$"

    assert has_element?(view, "#entry-post-text[class*=whitespace-pre-wrap]")
    assert has_element?(view, "#entry-title[class*=line-clamp-3]", "Sunset at the lake")

    assert has_element?(view, "#entry-title[title^='Sunset at the lake']")
  end

  test "describes the album's media and delivery", %{conn: conn} do
    entry = album_fixture()
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-album-badge", "Album")
    assert has_element?(view, "#entry-album-items", "1 photo · 1 video")
    refute has_element?(view, "#media-panel", "Video codec")

    assert has_element?(view, "#entry-sent-items", "2 of 2 items")
    assert has_element?(view, "#telegram-panel", "First message")
    assert has_element?(view, "#telegram-panel", "#501")
    refute has_element?(view, "#entry-file-id")

    assert has_element?(view, "#retry-entry[data-confirm*='all 2 items of this album']")

    assert has_element?(
             view,
             "#purge-entry[data-confirm='Delete the stored files? The entry itself stays.']"
           )
  end

  test "counts photos and videos", %{conn: conn} do
    entry = album_fixture(%{media_items: [photo(), photo(), video(), photo(), video()]})
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-album-items", "3 photos · 2 videos")
    assert has_element?(view, "#entry-album[data-count='5']")
  end

  test "shows a single photo as a photo", %{conn: conn} do
    entry = album_fixture(%{media_items: [photo()]})
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-album-badge", "Photo")
    assert has_element?(view, "#entry-album[data-count='1'] #entry-media-0 img")
    assert has_element?(view, "#entry-album-items", "1 photo")
    assert has_element?(view, "#entry-sent-items", ~r/^1 of 1 item$/)
    assert has_element?(view, "#retry-entry[data-confirm*='this photo']")
  end

  test "marks items whose file is missing", %{conn: conn} do
    entry = album_fixture()
    File.rm!(Path.join(entry.storage_path, "album/02/video.mp4"))
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-media-0 img")
    assert has_element?(view, "#entry-media-1 [data-role=missing]", "Not stored")
    refute has_element?(view, "#entry-media-1 video")
  end

  test "keeps the post text when the files were deleted", %{conn: conn} do
    entry = album_fixture() |> Storage.purge()
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    refute has_element?(view, "#entry-album")
    assert has_element?(view, "#no-preview", "The files were removed from storage")
    assert has_element?(view, "#entry-post-text", "Sunset at the lake")
    refute has_element?(view, "#purge-entry")
  end

  test "asks before sending a partly delivered album again", %{conn: conn} do
    entry =
      album_fixture(%{
        status: :failed,
        error_kind: :telegram,
        error: "Only 1 of 2 items were sent: Too Many Requests: retry after 30",
        media_items: [photo(), MediaItem.new(%{video() | file_id: nil})]
      })

    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    assert has_element?(view, "#entry-sent-items", "1 of 2 items")

    assert has_element?(
             view,
             "#retry-entry[data-confirm='1 of 2 items were already sent. Send the whole album again?']",
             "Retry"
           )
  end

  test "follows changes of the album", %{conn: conn} do
    entry = album_fixture()
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")
    assert has_element?(view, "#entry-album[data-count='2']")

    Entries.update!(entry, %{media_items: [hd(entry.media_items)]})

    assert has_element?(view, "#entry-album[data-count='1']")
    assert has_element?(view, "#entry-album-badge", "Photo")
  end

  test "names videos neutrally", %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: "https://youtu.be/#{n}", chat_id: 1, chat_type: "private", message_id: n}
      ])

    entry = Entries.update!(entry, %{status: :done, media_kind: :video})
    {:ok, view, _html} = live(conn, ~p"/entries/#{entry.id}")

    refute has_element?(view, "#entry-album-badge")
    refute has_element?(view, "#entry-post-text")
    assert has_element?(view, "#no-preview", "The files aren't stored on this server.")

    assert has_element?(
             view,
             "#retry-entry[data-confirm='Download and send this to the chat again?']"
           )
  end

  defp photo, do: MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "photo"})

  defp video do
    MediaItem.new(%{
      type: :video,
      path: "album/02/video.mp4",
      thumbnail: "album/02/thumbnail.jpg",
      duration: 12,
      file_id: "video"
    })
  end
end
