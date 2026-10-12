defmodule Angler.Media.AlbumTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Angler.Media.{Album, Download, Error}
  alias Angler.Media.Instagram.Post

  @moduletag :tmp_dir
  @moduletag :capture_log

  @cdn "https://scontent-iev1-1.cdninstagram.com"

  defp photo(n) do
    %{
      type: :photo,
      urls: [
        "#{@cdn}/v/t51/photo-#{n}.jpg?oh=signed",
        "#{@cdn}/v/t51/photo-#{n}-1080.jpg?oh=signed"
      ],
      width: 1080,
      height: 1440,
      duration: nil
    }
  end

  defp video(n) do
    %{
      type: :video,
      urls: ["#{@cdn}/o1/v/t16/video-#{n}.mp4?oh=signed"],
      width: 1080,
      height: 1350,
      duration: 17.875
    }
  end

  defp post(items, opts \\ []) do
    %Post{
      code: "DduKfFmDxsG",
      caption: Keyword.get(opts, :caption, "Two things\nfrom today"),
      username: "instagram",
      webpage_url: "https://www.instagram.com/p/DduKfFmDxsG/",
      items: items
    }
  end

  # Serves each file as its name ("photo-1.jpg" is "photo-1"), or through `handler`
  # (called with the conn and the file name without extension). Every request is
  # sent to the test process as `{:cdn_request, "host/path", conn}`.
  defp stub_cdn(handler \\ fn conn, name -> bytes(conn, name) end) do
    test = self()

    Req.Test.stub(Angler.Media.Instagram, fn conn ->
      send(test, {:cdn_request, conn.host <> conn.request_path, conn})
      handler.(conn, conn.request_path |> Path.basename() |> Path.rootname())
    end)
  end

  defp bytes(conn, body), do: Plug.Conn.send_resp(conn, 200, body)

  defp download(post, dir, opts \\ []) do
    test = self()
    Album.download(post, dir, Keyword.put_new(opts, :on_progress, &send(test, {:progress, &1})))
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  describe "download/3" do
    test "downloads the items in display order, each into its own directory", %{tmp_dir: dir} do
      stub_cdn()

      assert {:ok, %Download{} = download} =
               download(post([photo(1), video(2), photo(3)]), dir, max_duration: 600)

      album = Path.join(dir, "album")

      assert %Download{
               kind: :album,
               path: ^album,
               title: "Two things\nfrom today",
               extractor: "Instagram",
               webpage_url: "https://www.instagram.com/p/DduKfFmDxsG/",
               max_duration: 600
             } = download

      assert download.items == [
               %{
                 type: :photo,
                 path: Path.join(album, "01/source.jpg"),
                 size: 7,
                 width: 1080,
                 height: 1440,
                 duration: nil
               },
               %{
                 type: :video,
                 path: Path.join(album, "02/source.mp4"),
                 size: 7,
                 width: 1080,
                 height: 1350,
                 duration: 17.875
               },
               %{
                 type: :photo,
                 path: Path.join(album, "03/source.jpg"),
                 size: 7,
                 width: 1080,
                 height: 1440,
                 duration: nil
               }
             ]

      assert download.size == 21
      assert File.read!(Path.join(album, "02/source.mp4")) == "video-2"

      progress = progress_messages()
      assert %{percent: 2 / 3 * 100, detail: "Downloading 2/3"} in progress
      assert List.last(progress) == %{percent: 100.0, detail: "Downloading 3/3"}

      # The original of each photo was enough; no cookies go to the CDN.
      for _n <- 1..3 do
        assert_received {:cdn_request, "scontent-iev1-1.cdninstagram.com/" <> _path, conn}
        assert Plug.Conn.get_req_header(conn, "cookie") == []
      end

      refute_received {:cdn_request, _path, _conn}
    end

    test "titles the album after the post text or its author", %{tmp_dir: dir} do
      stub_cdn()

      assert {:ok, %Download{title: "Post by @instagram"}} =
               download(post([photo(1)], caption: nil), dir)
    end

    test "falls back to the smaller version of a photo", %{tmp_dir: dir} do
      stub_cdn(fn conn, name ->
        if name == "photo-2",
          do: Plug.Conn.send_resp(conn, 403, "Bad URL hash"),
          else: bytes(conn, name)
      end)

      assert {:ok, %Download{items: [_first, second]}} =
               download(post([photo(1), photo(2)]), dir, final_attempt: false)

      assert File.read!(second.path) == "photo-2-1080"
    end

    test "retries items the CDN refuses while more attempts follow", %{tmp_dir: dir} do
      # Signed URLs expire: the next attempt loads the post again.
      stub_cdn(fn conn, name ->
        if name =~ "photo-2", do: Plug.Conn.send_resp(conn, 403, ""), else: bytes(conn, name)
      end)

      assert {:error,
              %Error{
                kind: :transient,
                message: "Could not download item 2 of the Instagram post (HTTP 403, HTTP 403)"
              }} = download(post([photo(1), photo(2), video(3)]), dir, final_attempt: false)
    end

    test "leaves out items the CDN refuses on the final attempt", %{tmp_dir: dir} do
      stub_cdn(fn conn, name ->
        if name =~ "photo-2", do: Plug.Conn.send_resp(conn, 404, ""), else: bytes(conn, name)
      end)

      log =
        capture_log(fn ->
          assert {:ok, %Download{items: items, size: 14}} =
                   download(post([photo(1), photo(2), video(3)]), dir, final_attempt: true)

          assert Enum.map(items, & &1.path) ==
                   Enum.map(["01/source.jpg", "03/source.mp4"], &Path.join([dir, "album", &1]))
        end)

      assert log =~ "Skipping item 2 of an Instagram post: HTTP 404, HTTP 404"
      assert dir |> Path.join("album") |> File.ls!() |> Enum.sort() == ["01", "03"]
    end

    test "network trouble and server errors are transient", %{tmp_dir: dir} do
      stub_cdn(fn conn, name ->
        cond do
          name == "video-2" -> Req.Test.transport_error(conn, :econnreset)
          name =~ "photo-3" -> Plug.Conn.send_resp(conn, 503, "")
          true -> bytes(conn, name)
        end
      end)

      assert {:error, %Error{kind: :transient, message: message}} =
               download(post([photo(1), video(2)]), dir)

      assert message =~ "Could not download item 2 of the Instagram post"

      assert {:error, %Error{kind: :transient, message: message}} =
               download(post([photo(3)]), Path.join(dir, "again"))

      assert message == "Could not download item 1 of the Instagram post (HTTP 503, HTTP 503)"
    end

    test "does not follow redirects", %{tmp_dir: dir} do
      stub_cdn(fn conn, name ->
        if name == "video-1" do
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/video.mp4")
          |> Plug.Conn.send_resp(302, "")
        else
          bytes(conn, name)
        end
      end)

      assert {:error, %Error{kind: :transient, message: message}} =
               download(post([video(1)]), dir, final_attempt: false)

      assert message =~ "(HTTP 302)"
      refute_received {:cdn_request, "attacker.test" <> _path, _conn}
    end

    test "only downloads from Instagram's CDN and logs only the host", %{tmp_dir: dir} do
      stub_cdn()
      elsewhere = %{photo(2) | urls: ["https://files.evil.test/photo-2.jpg?oh=secret-signature"]}

      assert {:error,
              %Error{
                kind: :transient,
                message:
                  "Could not download item 2 of the Instagram post (files.evil.test is not an allowed host)"
              }} = download(post([photo(1), elsewhere]), dir, final_attempt: false)

      log =
        capture_log(fn ->
          assert {:ok, %Download{items: [_only]}} =
                   download(post([photo(1), elsewhere]), Path.join(dir, "final"))
        end)

      assert log =~ "files.evil.test"
      refute log =~ "secret-signature"
      refute_received {:cdn_request, "files.evil.test" <> _path, _conn}
    end

    test "refuses posts larger than the source limit, counting parallel downloads", %{
      tmp_dir: dir
    } do
      stub_cdn(fn conn, _name -> bytes(conn, :binary.copy("x", 300_000)) end)

      assert {:error,
              %Error{kind: :too_large, message: "This Instagram post is larger than 1 MB"}} =
               download(post(Enum.map(1..5, &video/1)), dir, max_source_bytes: 1_000_000)

      assert {:ok, %Download{size: 900_000}} =
               download(post(Enum.map(1..3, &video/1)), Path.join(dir, "fits"),
                 max_source_bytes: 1_000_000
               )
    end

    test "leaves out a photo larger than 30 MB", %{tmp_dir: dir} do
      big = :binary.copy(<<0>>, 30_000_001)

      stub_cdn(fn conn, name ->
        if name =~ "photo-1", do: bytes(conn, big), else: bytes(conn, name)
      end)

      assert {:ok, %Download{items: [only]}} = download(post([photo(1), photo(2)]), dir)
      assert File.read!(only.path) == "photo-2"
    end

    test "fails when nothing could be downloaded", %{tmp_dir: dir} do
      stub_cdn(fn conn, _name -> Plug.Conn.send_resp(conn, 410, "") end)

      assert {:error,
              %Error{kind: :unavailable, message: "Could not download the Instagram post"}} =
               download(post([photo(1), video(2)]), dir)

      assert {:error,
              %Error{kind: :unsupported, message: "This Instagram post has no photos or videos"}} =
               download(post([]), Path.join(dir, "empty"))
    end

    test "names a Threads post as such", %{tmp_dir: dir} do
      stub_cdn(fn conn, name ->
        if name =~ "photo-2", do: Plug.Conn.send_resp(conn, 404, ""), else: bytes(conn, name)
      end)

      post = %{post([photo(1), photo(2)]) | site: "Threads", caption: nil}

      log =
        capture_log(fn ->
          assert {:ok, %Download{extractor: "Threads", title: "Post by @instagram"}} =
                   download(post, dir)
        end)

      assert log =~ "Skipping item 2 of a Threads post: HTTP 404, HTTP 404"

      assert {:error, %Error{message: "This Threads post has no photos or videos"}} =
               download(%{post | items: []}, Path.join(dir, "empty"))
    end

    test "downloads at most 20 items", %{tmp_dir: dir} do
      stub_cdn()

      assert {:ok, %Download{items: items}} = download(post(Enum.map(1..22, &photo/1)), dir)
      assert length(items) == 20
      assert List.last(items).path == Path.join([dir, "album", "20", "source.jpg"])
    end
  end
end
