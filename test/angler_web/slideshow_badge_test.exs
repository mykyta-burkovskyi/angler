defmodule AnglerWeb.SlideshowBadgeTest do
  # The "slideshow" badge next to "transcoded", in the entry list and on the entry page.
  # Not async: the entry page subscribes to entry broadcasts, which other tests send too.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias AnglerWeb.EntryComponents

  defp row(attrs) do
    entry =
      struct!(
        %Entry{
          id: Ecto.UUID.generate(),
          status: :done,
          url: "https://www.tiktok.com/@user/photo/1",
          source_host: "tiktok.com",
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

  test "entry rows mark slideshows" do
    html = row(transcoded: true, media_kind: :slideshow)
    assert count(html, "[data-role=transcoded]") == 1
    assert html |> LazyHTML.query("[data-role=slideshow]") |> LazyHTML.text() =~ "slideshow"

    assert count(row(transcoded: true, media_kind: :video), "[data-role=slideshow]") == 0
    assert count(row(media_kind: nil), "[data-role=slideshow]") == 0
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
            url: "https://www.tiktok.com/@user/photo/#{n}",
            source_host: "tiktok.com",
            chat_id: -1_001_234,
            chat_type: "supergroup",
            message_id: n
          }
        ])

      Entries.update!(entry, attrs)
    end

    test "shows the slideshow badge only for slideshows", %{conn: conn} do
      slideshow = entry_fixture(%{status: :done, transcoded: true, media_kind: :slideshow})
      {:ok, view, _html} = live(conn, ~p"/entries/#{slideshow.id}")
      assert has_element?(view, "#entry-slideshow", "Slideshow")

      video = entry_fixture(%{status: :done, transcoded: true, media_kind: :video})
      {:ok, view, _html} = live(conn, ~p"/entries/#{video.id}")
      refute has_element?(view, "#entry-slideshow")
    end
  end
end
