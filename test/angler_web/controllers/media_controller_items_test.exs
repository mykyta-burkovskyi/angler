defmodule AnglerWeb.MediaControllerItemsTest do
  # Album files live in their entry's own directory under the configured storage
  # root (the application env is not changed).
  use AnglerWeb.ConnCase, async: true

  import AnglerWeb.EntriesLiveTestHelpers, only: [album_fixture: 0, album_files: 0]

  alias Angler.Entries
  alias Angler.Entries.MediaItem

  setup %{conn: conn} do
    authorized = put_req_header(conn, "authorization", basic_auth("admin", "test-password"))
    {:ok, conn: authorized, entry: album_fixture()}
  end

  describe "authentication" do
    test "requires the dashboard credentials", %{entry: entry} do
      assert build_conn() |> get(~p"/media/#{entry.id}/items/0") |> response(401)

      assert build_conn()
             |> put_req_header("authorization", basic_auth("admin", "wrong"))
             |> get(~p"/media/#{entry.id}/items/1/thumbnail")
             |> response(401)
    end
  end

  describe "GET /media/:id/items/:index" do
    test "sends a photo as an image the browser may cache", %{conn: conn, entry: entry} do
      conn = get(conn, ~p"/media/#{entry.id}/items/0")

      assert response(conn, 200) == album_files()["album/01/photo.jpg"]
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "sends PNG and WebP photos with their content type", %{conn: conn, entry: entry} do
      write!(entry, "album/03/photo.png", "png bytes")
      write!(entry, "album/04/photo.webp", "webp bytes")

      entry =
        Entries.update!(entry, %{
          media_items:
            entry.media_items ++
              [
                MediaItem.new(%{type: :photo, path: "album/03/photo.png"}),
                MediaItem.new(%{type: :photo, path: "album/04/photo.webp"})
              ]
        })

      conn = get(conn, ~p"/media/#{entry.id}/items/2")
      assert response(conn, 200) == "png bytes"
      assert get_resp_header(conn, "content-type") == ["image/png"]

      conn = get(authorized_conn(), ~p"/media/#{entry.id}/items/3")
      assert response(conn, 200) == "webp bytes"
      assert get_resp_header(conn, "content-type") == ["image/webp"]
    end

    test "sends a video, with byte ranges", %{conn: conn, entry: entry} do
      video = album_files()["album/02/video.mp4"]

      conn = get(conn, ~p"/media/#{entry.id}/items/1")
      assert response(conn, 200) == video
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "cache-control") != ["private, max-age=3600"]

      conn =
        authorized_conn()
        |> put_req_header("range", "bytes=10-19")
        |> get(~p"/media/#{entry.id}/items/1")

      assert response(conn, 206) == binary_part(video, 10, 10)
      assert get_resp_header(conn, "content-range") == ["bytes 10-19/1000"]

      conn =
        authorized_conn()
        |> put_req_header("range", "bytes=1000-")
        |> get(~p"/media/#{entry.id}/items/1")

      assert response(conn, 416) == ""
    end

    test "answers HEAD requests without a body", %{conn: conn, entry: entry} do
      conn = head(conn, ~p"/media/#{entry.id}/items/1")

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
    end

    test "accepts an index with a leading zero", %{conn: conn, entry: entry} do
      assert conn |> get("/media/#{entry.id}/items/01") |> response(200) ==
               album_files()["album/02/video.mp4"]
    end
  end

  describe "GET /media/:id/items/:index/thumbnail" do
    test "sends a video's thumbnail", %{conn: conn, entry: entry} do
      conn = get(conn, ~p"/media/#{entry.id}/items/1/thumbnail")

      assert response(conn, 200) == album_files()["album/02/thumbnail.jpg"]
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "404 for a photo, which has no thumbnail", %{conn: conn, entry: entry} do
      assert conn |> get(~p"/media/#{entry.id}/items/0/thumbnail") |> response(404)
    end
  end

  describe "invalid indexes" do
    test "404 for indexes that aren't plain digits in range", %{entry: entry} do
      # As sent: "%2B1" and "%2F" reach the controller as "+1" and "/".
      indexes =
        ["2", "99", "100", "-1", "+1", "%2B1", "%201", "1%20", "1.0", "1e0", "0x1", "x"] ++
          ["%D9%A1", "..", "..%2F", "..%2F..%2Fthumbnail.jpg", "%2E%2E", "0%00", "1%2F.."]

      for index <- indexes, suffix <- ["", "/thumbnail"] do
        path = "/media/#{entry.id}/items/#{index}#{suffix}"
        conn = get(authorized_conn(), path)

        assert conn.status == 404, "expected 404 for #{inspect(path)}, got #{conn.status}"
      end
    end

    test "404 for a dot segment in place of the index", %{conn: conn, entry: entry} do
      assert conn |> get("/media/#{entry.id}/items/../thumbnail") |> response(404)
    end
  end

  describe "missing media" do
    test "404 for unknown or invalid ids", %{conn: conn} do
      assert conn |> get(~p"/media/#{Ecto.UUID.generate()}/items/0") |> response(404)
      assert authorized_conn() |> get(~p"/media/not-a-uuid/items/0") |> response(404)
      assert authorized_conn() |> get(~p"/media/not-a-uuid/items/1/thumbnail") |> response(404)
    end

    test "404 for entries without items", %{conn: conn} do
      n = System.unique_integer([:positive])

      {:ok, [video]} =
        Entries.enqueue([
          %{url: "https://example.com/v/#{n}", chat_id: 1, chat_type: "private", message_id: n}
        ])

      assert conn |> get(~p"/media/#{video.id}/items/0") |> response(404)
    end

    test "404 when an item's file is gone from disk", %{conn: conn, entry: entry} do
      File.rm!(Path.join(entry.storage_path, "album/01/photo.jpg"))
      File.rm!(Path.join(entry.storage_path, "album/02/thumbnail.jpg"))

      assert conn |> get(~p"/media/#{entry.id}/items/0") |> response(404)
      assert authorized_conn() |> get(~p"/media/#{entry.id}/items/1/thumbnail") |> response(404)
      assert authorized_conn() |> get(~p"/media/#{entry.id}/items/1") |> response(200)
    end
  end

  describe "stored paths are never trusted" do
    test "404 for stored paths outside the entry's directory", %{entry: entry} do
      other = album_fixture()
      other_dir = Path.basename(other.storage_path)

      paths = [
        "../#{other_dir}/album/01/photo.jpg",
        "album/01/../../../#{other_dir}/album/01/photo.jpg",
        "album/../thumbnail.jpg",
        "thumbnail.jpg",
        "album/01/source.jpg",
        Path.join(other.storage_path, "album/01/photo.jpg"),
        "album/1/photo.jpg"
      ]

      entry =
        Entries.update!(entry, %{
          media_items: Enum.map(paths, &MediaItem.new(%{type: :photo, path: &1, thumbnail: &1}))
        })

      for index <- 0..(length(paths) - 1), suffix <- ["", "/thumbnail"] do
        path = "/media/#{entry.id}/items/#{index}#{suffix}"
        assert authorized_conn() |> get(path) |> response(404), "expected 404 for #{path}"
      end
    end

    test "404 for symlinks, even to files of the entry", %{conn: conn, entry: entry} do
      dir = entry.storage_path
      File.mkdir_p!(Path.join(dir, "album/03"))
      File.ln_s!(Path.join(dir, "album/01/photo.jpg"), Path.join(dir, "album/03/photo.jpg"))
      File.ln_s!(Path.join(dir, "album/02"), Path.join(dir, "album/04"))

      entry =
        Entries.update!(entry, %{
          media_items:
            entry.media_items ++
              [
                MediaItem.new(%{type: :photo, path: "album/03/photo.jpg"}),
                MediaItem.new(%{type: :video, path: "album/04/video.mp4"})
              ]
        })

      assert conn |> get(~p"/media/#{entry.id}/items/2") |> response(404)
      assert authorized_conn() |> get(~p"/media/#{entry.id}/items/3") |> response(404)
    end

    @tag :tmp_dir
    test "404 when the entry's directory is outside the storage root", %{
      conn: conn,
      tmp_dir: outside
    } do
      File.mkdir_p!(Path.join(outside, "album/01"))
      File.write!(Path.join(outside, "album/01/photo.jpg"), "outside")

      entry = Entries.update!(album_fixture(), %{storage_path: outside})

      assert conn |> get(~p"/media/#{entry.id}/items/0") |> response(404)
    end
  end

  defp write!(entry, relative, bytes) do
    path = Path.join(entry.storage_path, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp authorized_conn do
    put_req_header(build_conn(), "authorization", basic_auth("admin", "test-password"))
  end

  defp basic_auth(username, password), do: Plug.BasicAuth.encode_basic_auth(username, password)
end
