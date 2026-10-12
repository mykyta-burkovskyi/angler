defmodule Angler.Media.Threads.PageTest do
  use ExUnit.Case, async: true

  import Angler.ThreadsFixtures

  alias Angler.InstagramFixtures
  alias Angler.Media.Threads.Page

  describe "read/2" do
    test "reads the post from a recorded page" do
      assert {:ok, %{"code" => "DeUWxGgjHSK", "media_type" => 1} = media} =
               Page.read(recorded("page_photo_DeUWxGgjHSK.html"), "DeUWxGgjHSK")

      assert get_in(media, ["user", "username"]) == "nasa"
      assert [%{"url" => "https://" <> _} | _] = get_in(media, ["image_versions2", "candidates"])
    end

    test "reads the post its page shows, not the related posts" do
      media = media("DeMqtuYgkaL")

      assert Page.read(page(media), "DeMqtuYgkaL") == {:ok, media}

      assert Page.read(page(media), "Crelated") ==
               {:ok,
                %{"code" => "Crelated", "media_type" => 1, "caption" => %{"text" => "Other"}}}
    end

    test "finds the post by its code and shape, whatever the query is called" do
      media = media("DeUWxGgjHSK")
      blob = Jason.encode!(%{"require" => [["Renamed", %{"answer" => %{"post" => media}}]]})
      html = ~s(<script type="application/json" data-sjs>#{blob}</script>)

      assert Page.read(html, "DeUWxGgjHSK") == {:ok, media}
    end

    test "gives up on pages without the post" do
      assert Page.read(shell(), "DeUWxGgjHSK") == {:gave_up, "no post data in the post page"}

      assert Page.read("<html></html>", "DeUWxGgjHSK") ==
               {:gave_up, "no post data in the post page"}

      broken = ~s(<script type="application/json" data-sjs>{"code":"DeUWxGgjHSK",</script>)
      assert Page.read(broken, "DeUWxGgjHSK") == {:gave_up, "no post data in the post page"}
    end

    test "reads a post Threads marks unavailable as missing" do
      media =
        Map.put(media("DeUWxGgjHSK"), "text_post_app_info", %{"is_post_unavailable" => true})

      assert Page.read(page(media), "DeUWxGgjHSK") == :missing
    end
  end

  describe "fetch/2" do
    test "loads the page like a browser navigation, without cookies" do
      stub_threads(&html(&1, recorded("page_photo_DeUWxGgjHSK.html")))

      assert {:ok, %{"code" => "DeUWxGgjHSK"}} = Page.fetch("DeUWxGgjHSK", "nasa")

      assert_received {:threads_request, "GET", "www.threads.com/@nasa/post/DeUWxGgjHSK", conn}
      assert Plug.Conn.get_req_header(conn, "sec-fetch-mode") == ["navigate"]
      assert [accept] = Plug.Conn.get_req_header(conn, "accept")
      assert accept =~ "text/html"
      assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      assert user_agent =~ "Chrome/"
      assert Plug.Conn.get_req_header(conn, "cookie") == []
    end

    test "loads /t/<code> without a username, and follows its redirect to the post once" do
      stub_threads(fn conn ->
        case conn.request_path do
          "/t/DeUWxGgjHSK" ->
            InstagramFixtures.redirect(
              conn,
              "https://www.threads.com/@nasa/post/DeUWxGgjHSK",
              301
            )

          "/@nasa/post/DeUWxGgjHSK" ->
            html(conn, recorded("page_photo_DeUWxGgjHSK.html"))
        end
      end)

      assert {:ok, %{"code" => "DeUWxGgjHSK"}} = Page.fetch("DeUWxGgjHSK", nil)
      assert_received {:threads_request, "GET", "www.threads.com/t/DeUWxGgjHSK", _conn}
      assert_received {:threads_request, "GET", "www.threads.com/@nasa/post/DeUWxGgjHSK", _conn}
    end

    test "follows a redirect to the post's own username (rebuilt, without its query)" do
      stub_threads(fn conn ->
        case conn.request_path do
          "/@zuck/post/DeUWxGgjHSK" ->
            InstagramFixtures.redirect(conn, "/@nasa/post/DeUWxGgjHSK?xmt=1", 301)

          "/@nasa/post/DeUWxGgjHSK" ->
            assert conn.query_string == ""
            html(conn, recorded("page_photo_DeUWxGgjHSK.html"))
        end
      end)

      assert {:ok, %{"code" => "DeUWxGgjHSK"}} = Page.fetch("DeUWxGgjHSK", "zuck")
    end

    test "follows no other redirect" do
      for location <- [
            "https://www.threads.com/@nasa/post/DeOTHERCODE",
            "https://evil.test/@nasa/post/DeUWxGgjHSK",
            "https://threads.net/@nasa/post/DeUWxGgjHSK",
            "https://www.threads.com/@nasa"
          ] do
        stub_threads(&InstagramFixtures.redirect(&1, location, 301))

        assert Page.fetch("DeUWxGgjHSK", "zuck") ==
                 {:gave_up, "the post page redirected elsewhere"}

        assert_received {:threads_request, "GET", _path, _conn}
        refute_received {:threads_request, "GET", _path, _conn}
      end
    end

    test "follows one redirect at most" do
      stub_threads(fn conn ->
        InstagramFixtures.redirect(conn, "https://www.threads.com/@other/post/DeUWxGgjHSK", 301)
      end)

      assert Page.fetch("DeUWxGgjHSK", "nasa") == {:gave_up, "the post page redirected elsewhere"}
      assert_received {:threads_request, "GET", "www.threads.com/@nasa/post/DeUWxGgjHSK", _conn}
      assert_received {:threads_request, "GET", "www.threads.com/@other/post/DeUWxGgjHSK", _conn}
      refute_received {:threads_request, _method, _path, _conn}
    end

    test "reads Threads' invalid post redirect as a missing post" do
      stub_threads(&InstagramFixtures.redirect(&1, "https://www.threads.com/?error=invalid_post"))
      assert Page.fetch("DeUWxGgjHSX", "nasa") == :missing
    end

    test "gives up on login redirects, other answers and network errors" do
      stub_threads(&InstagramFixtures.redirect(&1, "https://www.threads.com/login?next=/x"))

      assert Page.fetch("DeUWxGgjHSK", "nasa") ==
               {:gave_up, "the post page redirected to the login page"}

      stub_threads(&Plug.Conn.send_resp(&1, 302, ""))

      assert Page.fetch("DeUWxGgjHSK", "nasa") ==
               {:gave_up, "the post page redirected without a location"}

      stub_threads(&Plug.Conn.send_resp(&1, 503, ""))

      assert Page.fetch("DeUWxGgjHSK", "nasa") ==
               {:gave_up, "the post page answered with HTTP 503"}

      stub_threads(&Req.Test.transport_error(&1, :econnrefused))
      assert {:gave_up, "the post page: " <> _reason} = Page.fetch("DeUWxGgjHSK", "nasa")
    end

    test "reports rate limiting" do
      stub_threads(&Plug.Conn.send_resp(&1, 429, ""))

      assert Page.fetch("DeUWxGgjHSK", "nasa") ==
               {:rate_limited, "the post page answered with HTTP 429"}
    end
  end
end
