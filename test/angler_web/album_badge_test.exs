defmodule AnglerWeb.AlbumBadgeTest do
  # The "album" chip next to "transcoded" in the entry list, and the "Album" badge on
  # the entry page.
  # Not async: the entry page subscribes to entry broadcasts, which other tests send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Entries
  alias Angler.Entries.{Entry, MediaItem}
  alias AnglerWeb.EntryComponents

  defp row(attrs) do
    entry =
      struct!(
        %Entry{
          id: Ecto.UUID.generate(),
          status: :done,
          url: "https://www.instagram.com/p/C1/",
          source_host: "instagram.com",
          chat_id: -1001,
          chat_type: "supergroup",
          message_id: 7,
          inserted_at: DateTime.utc_now(),
          available_at: DateTime.utc_now()
        },
        attrs
      )

    component = &EntryComponents.entry_row/1

    component
    |> render_component(id: "entry-#{entry.id}", entry: entry)
    |> LazyHTML.from_fragment()
  end

  defp count(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count()

  defp chip(html) do
    html |> LazyHTML.query("[data-role=album]") |> LazyHTML.text() |> String.trim()
  end

  defp items(types), do: Enum.map(types, &MediaItem.new(%{type: &1}))

  test "entry rows mark albums with their number of items" do
    html = row(transcoded: true, media_kind: :album, media_items: items([:photo, :video, :photo]))
    assert count(html, "[data-role=transcoded]") == 1
    assert chip(html) == "album · 3"
    assert count(html, "[data-role=slideshow]") == 0

    # Not prepared yet: the number is unknown.
    assert chip(row(status: :downloading, media_kind: :album)) == "album"
  end

  test "entry rows mark a single photo as a photo" do
    assert chip(row(media_kind: :album, media_items: items([:photo]))) == "photo"
    assert chip(row(media_kind: :album, media_items: items([:video]))) == "album"
  end

  test "entry rows of videos and slideshows have no album chip" do
    assert count(row(media_kind: :video), "[data-role=album]") == 0
    assert count(row(media_kind: :slideshow), "[data-role=album]") == 0
    assert count(row(media_kind: nil), "[data-role=album]") == 0
  end

  describe "entry page" do
    setup %{conn: conn} do
      auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
      %{conn: put_req_header(conn, "authorization", auth)}
    end

    defp entry_fixture(attrs) do
      n = System.unique_integer([:positive])

      {:ok, [entry]} =
        Entries.enqueue([
          %{
            url: "https://www.instagram.com/p/C#{n}/",
            source_host: "instagram.com",
            chat_id: -1_001_234,
            chat_type: "supergroup",
            message_id: n
          }
        ])

      Entries.update!(entry, attrs)
    end

    test "shows the album badge only for albums", %{conn: conn} do
      album =
        entry_fixture(%{status: :done, media_kind: :album, media_items: items([:photo, :video])})

      {:ok, view, _html} = live(conn, ~p"/entries/#{album.id}")
      assert has_element?(view, "#entry-album-badge", "Album")
      refute has_element?(view, "#entry-slideshow")

      photo = entry_fixture(%{status: :done, media_kind: :album, media_items: items([:photo])})
      {:ok, view, _html} = live(conn, ~p"/entries/#{photo.id}")
      assert has_element?(view, "#entry-album-badge", "Photo")

      video = entry_fixture(%{status: :done, transcoded: true, media_kind: :video})
      {:ok, view, _html} = live(conn, ~p"/entries/#{video.id}")
      refute has_element?(view, "#entry-album-badge")

      slideshow = entry_fixture(%{status: :done, media_kind: :slideshow})
      {:ok, view, _html} = live(conn, ~p"/entries/#{slideshow.id}")
      refute has_element?(view, "#entry-album-badge")
    end

    test "the list marks albums", %{conn: conn} do
      album =
        entry_fixture(%{status: :done, media_kind: :album, media_items: items([:photo, :photo])})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#entry-#{album.id} [data-role=album]", "album · 2")
    end
  end
end
