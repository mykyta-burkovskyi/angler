defmodule AnglerWeb.MediaControllerTest do
  # Changes the application env (data dir).
  use AnglerWeb.ConnCase, async: false

  alias Angler.Entries
  alias Angler.Storage

  @moduletag :tmp_dir
  @video for i <- 0..999, into: <<>>, do: <<rem(i, 256)>>
  @thumbnail "\xFF\xD8\xFF fake jpeg"

  setup %{conn: conn, tmp_dir: tmp_dir} do
    config = Application.fetch_env!(:angler, Angler.Media)
    Application.put_env(:angler, Angler.Media, Keyword.put(config, :data_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:angler, Angler.Media, config) end)

    authorized = put_req_header(conn, "authorization", basic_auth("admin", "test-password"))
    {:ok, conn: authorized, entry: stored_entry()}
  end

  describe "authentication" do
    test "requires the dashboard credentials", %{entry: entry} do
      assert build_conn() |> get(~p"/media/#{entry.id}/video") |> response(401)

      assert build_conn()
             |> put_req_header("authorization", basic_auth("admin", "wrong"))
             |> get(~p"/media/#{entry.id}/thumbnail")
             |> response(401)
    end
  end

  describe "GET /media/:id/video" do
    test "sends the whole file without a Range header", %{conn: conn, entry: entry} do
      conn = get(conn, ~p"/media/#{entry.id}/video")

      assert response(conn, 200) == @video
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-range") == []
    end

    test "sends a closed byte range", %{conn: conn, entry: entry} do
      conn = get_range(conn, entry, "bytes=0-99")

      assert response(conn, 206) == binary_part(@video, 0, 100)
      assert get_resp_header(conn, "content-range") == ["bytes 0-99/1000"]
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "sends an open-ended byte range", %{conn: conn, entry: entry} do
      conn = get_range(conn, entry, "bytes=900-")

      assert response(conn, 206) == binary_part(@video, 900, 100)
      assert get_resp_header(conn, "content-range") == ["bytes 900-999/1000"]
    end

    test "sends a suffix byte range", %{conn: conn, entry: entry} do
      conn = get_range(conn, entry, "bytes=-10")

      assert response(conn, 206) == binary_part(@video, 990, 10)
      assert get_resp_header(conn, "content-range") == ["bytes 990-999/1000"]
    end

    test "clamps ranges that extend past the end", %{conn: conn, entry: entry} do
      conn = get_range(conn, entry, "bytes=500-5000")
      assert response(conn, 206) == binary_part(@video, 500, 500)
      assert get_resp_header(conn, "content-range") == ["bytes 500-999/1000"]

      conn = get_range(build_authorized_conn(), entry, "bytes=-5000")
      assert response(conn, 206) == @video
      assert get_resp_header(conn, "content-range") == ["bytes 0-999/1000"]
    end

    test "answers 416 for unsatisfiable ranges", %{entry: entry} do
      for range <- ["bytes=1000-", "bytes=1000-1200", "bytes=-0", "bytes=50-10"] do
        conn = get_range(build_authorized_conn(), entry, range)

        assert response(conn, 416) == "", "expected 416 for #{range}"
        assert get_resp_header(conn, "content-range") == ["bytes */1000"]
      end
    end

    test "ignores Range headers it doesn't support", %{entry: entry} do
      for range <- ["bytes=0-1,5-6", "items=0-10", "bytes=abc", "bytes=-", "bytes"] do
        conn = get_range(build_authorized_conn(), entry, range)

        assert response(conn, 200) == @video, "expected the whole file for #{range}"
      end
    end

    test "answers HEAD requests without a body", %{conn: conn, entry: entry} do
      conn = head(conn, ~p"/media/#{entry.id}/video")

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]

      conn =
        build_authorized_conn()
        |> put_req_header("range", "bytes=0-9")
        |> head(~p"/media/#{entry.id}/video")

      assert response(conn, 206) == ""
      assert get_resp_header(conn, "content-range") == ["bytes 0-9/1000"]
    end
  end

  describe "GET /media/:id/thumbnail" do
    test "sends the thumbnail", %{conn: conn, entry: entry} do
      conn = get(conn, ~p"/media/#{entry.id}/thumbnail")

      assert response(conn, 200) == @thumbnail
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end
  end

  describe "missing media" do
    test "404 for unknown or invalid ids", %{conn: conn} do
      assert conn |> get(~p"/media/#{Ecto.UUID.generate()}/video") |> response(404)
      assert build_authorized_conn() |> get(~p"/media/not-a-uuid/thumbnail") |> response(404)
    end

    test "404 when the entry has no files", %{conn: conn} do
      entry = entry_fixture()

      assert conn |> get(~p"/media/#{entry.id}/video") |> response(404)
      assert build_authorized_conn() |> get(~p"/media/#{entry.id}/thumbnail") |> response(404)
    end

    test "404 when the file is gone from disk", %{conn: conn, entry: entry} do
      File.rm!(Storage.output_paths(entry.storage_path).video)
      File.rm!(Storage.output_paths(entry.storage_path).thumbnail)

      assert conn |> get(~p"/media/#{entry.id}/video") |> response(404)
      assert build_authorized_conn() |> get(~p"/media/#{entry.id}/thumbnail") |> response(404)
    end

    test "404 for files outside the storage root", %{conn: conn, tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(outside)
      File.write!(Storage.output_paths(outside).video, @video)
      entry = Entries.update!(entry_fixture(), %{status: :done, storage_path: outside})

      assert conn |> get(~p"/media/#{entry.id}/video") |> response(404)
    end
  end

  defp get_range(conn, entry, range) do
    conn
    |> put_req_header("range", range)
    |> get(~p"/media/#{entry.id}/video")
  end

  defp build_authorized_conn do
    put_req_header(build_conn(), "authorization", basic_auth("admin", "test-password"))
  end

  defp basic_auth(username, password), do: Plug.BasicAuth.encode_basic_auth(username, password)

  defp entry_fixture do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: "https://example.com/v/#{n}", chat_id: 1, chat_type: "private", message_id: n}
      ])

    entry
  end

  defp stored_entry do
    {:ok, dir, entry} = Storage.prepare_dir(entry_fixture())
    %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
    File.write!(video, @video)
    File.write!(thumbnail, @thumbnail)

    entry
    |> Storage.record_usage()
    |> Entries.mark_done()
  end
end
