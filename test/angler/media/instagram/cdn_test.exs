defmodule Angler.Media.Instagram.CdnTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures
  import ExUnit.CaptureLog

  alias Angler.Media.Instagram.Cdn

  @moduletag :tmp_dir

  @song "https://scontent-iev1-1.xx.fbcdn.net/o1/v/t2/f2/m69/song.mp4?efg=x&oh=00_sig"

  test "cdn?/1 accepts https URLs on Instagram's CDN hosts only" do
    for url <- [
          "https://scontent-iev1-1.cdninstagram.com/v/t51/1.jpg?oh=x",
          "https://SCONTENT.CDNINSTAGRAM.COM/v/1.jpg",
          "https://cdninstagram.com/1.jpg",
          "https://video.fiev1-1.fna.fbcdn.net/o1/v/t2/1.mp4",
          "https://scontent.cdninstagram.com:443/1.jpg"
        ] do
      assert Cdn.cdn?(url), url
    end

    for url <- [
          "http://scontent.cdninstagram.com/1.jpg",
          "https://user:pass@scontent.cdninstagram.com/1.jpg",
          "https://scontent.cdninstagram.com:8443/1.jpg",
          "https://evilcdninstagram.com/1.jpg",
          "https://cdninstagram.com.evil.test/1.jpg",
          "https://fbcdn.net.evil.test/1.jpg",
          "https://127.0.0.1/1.jpg",
          "file:///etc/passwd",
          "not a url",
          ""
        ] do
      refute Cdn.cdn?(url), url
    end

    refute Cdn.cdn?(nil)
  end

  describe "fetch/3" do
    test "downloads a file from the CDN without cookies", %{tmp_dir: dir} do
      stub_instagram(&bytes(&1, "song bytes", "video/mp4"))
      path = Path.join(dir, "audio.part")

      # No :timeout: it defaults to 2 minutes.
      assert Cdn.fetch(@song, path, max_bytes: 1_000) == {:ok, 10}
      assert File.read!(path) == "song bytes"

      assert_received {:instagram_request, "GET", "scontent-iev1-1.xx.fbcdn.net" <> _path, conn}
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      refute_received {:instagram_request, _method, _path, _conn}
    end

    test "applies the size limit and the shared budget", %{tmp_dir: dir} do
      stub_instagram(&bytes(&1, :binary.copy("x", 100), "video/mp4"))
      path = Path.join(dir, "audio.part")

      assert Cdn.fetch(@song, path, max_bytes: 99, timeout: 5_000) == {:error, :too_large}

      budget = Angler.Media.Fetch.budget(50)
      assert Cdn.fetch(@song, path, max_bytes: 1_000, budget: budget) == {:error, :over_budget}
    end

    test "refuses hosts that are not the CDN without a request and logs only the host", %{
      tmp_dir: dir
    } do
      stub_instagram(&bytes(&1, "never"))

      log =
        capture_log(fn ->
          assert Cdn.fetch("https://evil.test/x.mp4?oh=secret-signature", Path.join(dir, "x"),
                   max_bytes: 1_000
                 ) == {:error, {:host_not_allowed, "evil.test"}}
        end)

      assert log =~ "Not downloading Instagram media from evil.test"
      refute log =~ "x.mp4"
      refute log =~ "secret-signature"
      refute_received {:instagram_request, _method, _path, _conn}
    end

    test "does not follow redirects", %{tmp_dir: dir} do
      stub_instagram(fn conn ->
        if conn.host == "attacker.test",
          do: bytes(conn, "followed"),
          else: redirect(conn, "https://attacker.test/song.mp4")
      end)

      assert Cdn.fetch(@song, Path.join(dir, "audio.part"), max_bytes: 1_000) ==
               {:error, {:http, 302}}

      assert_received {:instagram_request, "GET", "scontent-iev1-1.xx.fbcdn.net" <> _path, _conn}
      refute_received {:instagram_request, _method, _path, _conn}
    end
  end
end
