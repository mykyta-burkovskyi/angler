defmodule Angler.Media.TikTok.PageCookiesTest do
  # The cookies file as a fallback for TikTok post pages. Changes the Angler.Media
  # and Angler.Media.TikTok application environment.
  use ExUnit.Case, async: false

  import Angler.TikTokFixtures

  alias Angler.Media
  alias Angler.Media.{Error, TikTok}
  alias Angler.Media.TikTok.Post

  @moduletag :tmp_dir
  @moduletag :capture_log

  @cookies """
  # Netscape HTTP Cookie File
  .tiktok.com\tTRUE\t/\tTRUE\t0\tsessionid\tS3SSION
  .tiktok.com\tTRUE\t/\tFALSE\t0\ttt_csrf_token\tcsrf
  .instagram.com\tTRUE\t/\tTRUE\t0\tsessionid\tinstagram-session
  """

  setup %{tmp_dir: tmp_dir} do
    original = Application.get_env(:angler, Media)
    original_tiktok = Application.get_env(:angler, TikTok)

    on_exit(fn ->
      Application.put_env(:angler, Media, original)
      Application.put_env(:angler, TikTok, original_tiktok)
    end)

    path = Path.join(tmp_dir, "cookies.txt")
    File.write!(path, @cookies)
    put_cookies_file(path)
    %{path: path}
  end

  defp put_cookies_file(path) do
    Application.put_env(
      :angler,
      Media,
      Keyword.put(Application.get_env(:angler, Media), :cookies_file, path)
    )
  end

  defp cookie_header(conn), do: Plug.Conn.get_req_header(conn, "cookie")

  # Answers logged-out loads with `logged_out` and loads with the file's cookies
  # with `logged_in`.
  defp stub_pages(logged_out, logged_in) do
    stub_tiktok(fn conn ->
      case cookie_header(conn) do
        [] -> logged_out.(conn)
        ["sessionid=S3SSION" <> _rest] -> logged_in.(conn)
      end
    end)
  end

  test "loads a post that is private to logged-out visitors once more with the cookies" do
    stub_pages(
      &Req.Test.html(&1, page(status_detail(10222))),
      &Req.Test.html(&1, page(detail(slideshow_item("7", 2))))
    )

    assert {:ok, {:slideshow, %Post{id: "7", images: [_, _]}}} =
             TikTok.resolve("https://www.tiktok.com/@a/photo/7")

    assert_received {:tiktok_request, "GET", "www.tiktok.com/@/video/7", first}
    assert cookie_header(first) == []
    assert_received {:tiktok_request, "GET", "www.tiktok.com/@/video/7", second}
    assert cookie_header(second) == ["sessionid=S3SSION; tt_csrf_token=csrf"]
    refute_received {:tiktok_request, _method, _path, _conn}
  end

  test "tries the cookies after a login redirect and after the logged-out attempts gave up" do
    for logged_out <- [
          &redirect(&1, "https://www.tiktok.com/login?redirect_url=x"),
          &Plug.Conn.send_resp(&1, 503, "")
        ] do
      stub_pages(logged_out, &Req.Test.html(&1, page(detail(video_item("8")))))

      assert TikTok.resolve("https://www.tiktok.com/@a/video/8") ==
               {:ok, :video, "https://www.tiktok.com/@/video/8"}
    end
  end

  test "keeps the logged-out result when the cookies don't help" do
    for logged_in <- [
          &Req.Test.html(&1, page(status_detail(10216))),
          &redirect(&1, "https://www.tiktok.com/login"),
          &Req.Test.html(&1, "<html>logged in, but different</html>"),
          &Req.Test.transport_error(&1, :econnreset)
        ] do
      stub_pages(&Req.Test.html(&1, page(status_detail(10222))), logged_in)

      assert {:error, %Error{kind: :unavailable, message: "This TikTok post is private"}} =
               TikTok.resolve("https://www.tiktok.com/@a/photo/9")
    end

    stub_pages(&Plug.Conn.send_resp(&1, 503, ""), &Req.Test.html(&1, page(status_detail(10204))))

    assert {:error,
            %Error{kind: :transient, message: "Could not load the TikTok post (HTTP 503)"}} =
             TikTok.resolve("https://www.tiktok.com/@a/photo/9")
  end

  test "sends a challenge answer together with the cookies" do
    stub_pages(&Req.Test.html(&1, page(status_detail(10222))), fn conn ->
      case cookie_header(conn) do
        ["sessionid=S3SSION; tt_csrf_token=csrf"] -> Req.Test.html(conn, challenge_page(12))
        [_with_answer] -> Req.Test.html(conn, page(detail(video_item("10"))))
      end
    end)

    assert {:ok, :video, _url} = TikTok.resolve("https://www.tiktok.com/@a/video/10")

    for _load <- 1..2, do: assert_received({:tiktok_request, "GET", _path, _conn})
    assert_received {:tiktok_request, "GET", _path, answered}
    assert [header] = cookie_header(answered)

    assert [
             "sessionid=S3SSION",
             "tt_csrf_token=csrf",
             "_wafchallengeid=" <> _,
             "waforiginalreid=rs-value-42"
           ] =
             String.split(header, "; ")
  end

  test "does not load the page again without cookies for TikTok", %{path: path} do
    File.write!(path, ".instagram.com\tTRUE\t/\tTRUE\t0\tsessionid\tinstagram-session\n")
    stub_tiktok(&Req.Test.html(&1, page(status_detail(10222))))

    assert {:error, %Error{kind: :unavailable}} =
             TikTok.resolve("https://www.tiktok.com/@a/video/11")

    assert_received {:tiktok_request, "GET", _path, _conn}
    refute_received {:tiktok_request, _method, _path, _conn}

    put_cookies_file(Path.join(Path.dirname(path), "missing.txt"))

    assert {:error, %Error{kind: :unavailable}} =
             TikTok.resolve("https://www.tiktok.com/@a/video/11")

    assert_received {:tiktok_request, "GET", _path, _conn}
    refute_received {:tiktok_request, _method, _path, _conn}
  end

  test "never sends the cookies to short links" do
    stub_tiktok(fn conn ->
      case conn.host do
        "vt.tiktok.com" -> redirect(conn, "https://www.tiktok.com/@/photo/12")
        "www.tiktok.com" -> Req.Test.html(conn, page(detail(slideshow_item("12", 1))))
      end
    end)

    assert {:ok, {:slideshow, %Post{id: "12"}}} = TikTok.resolve("https://vt.tiktok.com/ZSabc/")
    assert_received {:tiktok_request, "GET", "vt.tiktok.com/ZSabc/", short}
    assert cookie_header(short) == []
  end

  test "never follows redirects with the cookies, whatever the configuration says" do
    Application.put_env(
      :angler,
      TikTok,
      Keyword.update!(
        Application.get_env(:angler, TikTok),
        :req_options,
        &[{:redirect, true} | &1]
      )
    )

    stub_tiktok(fn conn ->
      case {conn.request_path, cookie_header(conn)} do
        {"/elsewhere", _cookies} -> Req.Test.html(conn, page(detail(video_item("13"))))
        {_page, []} -> Req.Test.html(conn, page(status_detail(10222)))
        {_page, [_cookies]} -> redirect(conn, "https://www.tiktok.com/elsewhere")
      end
    end)

    assert {:error, %Error{kind: :unavailable}} =
             TikTok.resolve("https://www.tiktok.com/@a/video/13")

    refute_received {:tiktok_request, "GET", "www.tiktok.com/elsewhere", _conn}
  end
end
