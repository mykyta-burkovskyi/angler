defmodule Angler.Media.ThreadsTest do
  use ExUnit.Case, async: true

  import Angler.ThreadsFixtures

  alias Angler.InstagramFixtures
  alias Angler.Media.{Error, Threads}
  alias Angler.Media.Instagram.{Music, Post}

  @moduletag :capture_log

  test "does not touch the network for other links" do
    stub_threads(fn _conn -> flunk("unexpected request") end)

    for url <- [
          "https://www.instagram.com/p/DeUWxGgjHSK/",
          "https://www.threads.com/@nasa",
          "https://www.tiktok.com/@a/video/1"
        ] do
      assert Threads.route(url) == :not_threads
    end
  end

  test "routes a single video to the CDN download, with the post's canonical URL" do
    stub_pages(%{"DeMqtuYgkaL" => media("DeMqtuYgkaL")})

    assert {:video, %Post{site: "Threads", items: [%{type: :video} = video]} = post} =
             Threads.route("https://www.threads.net/@nasa/post/DeMqtuYgkaL?xmt=abc")

    assert post.code == "DeMqtuYgkaL"
    assert post.webpage_url == "https://www.threads.com/@nasa/post/DeMqtuYgkaL"
    assert Post.title(post) =~ "Artemis II"
    assert video.duration == 89.365334
    assert [_url] = video.urls
  end

  test "routes carousels and photo posts without music to the album download" do
    stub_pages(%{"Ddt7cL5EfUG" => media("Ddt7cL5EfUG"), "DeUWxGgjHSK" => media("DeUWxGgjHSK")})

    assert {:album, %Post{site: "Threads", items: items}} =
             Threads.route("https://www.threads.com/@zuck/post/Ddt7cL5EfUG")

    assert Enum.map(items, & &1.type) ==
             ~w(photo photo photo photo photo video photo photo video)a

    assert {:album, %Post{items: [%{type: :photo}]} = post} =
             Threads.route("https://www.threads.com/t/DeUWxGgjHSK")

    # The username came from the post.
    assert post.webpage_url == "https://www.threads.com/@nasa/post/DeUWxGgjHSK"
  end

  test "routes a photo post with music to the slideshow, with a 30 s clip" do
    stub_pages(%{"DePPcDfkc_a" => media("DePPcDfkc_a")})

    assert {:slideshow, %Post{site: "Threads", items: [%{type: :photo}]}, %Music{} = music} =
             Threads.route("https://www.threads.com/@nasa/post/DePPcDfkc_a")

    assert {music.start, music.clip_duration} == {7.0, 30.0}
  end

  test "sends a photo post as an album when its music can't be used" do
    media =
      put_in(media("DePPcDfkc_a"), ["text_app_music_info", "is_available_for_consumption"], false)

    stub_pages(%{"DePPcDfkc_a" => media})

    assert {:album, %Post{items: [%{type: :photo}]}} =
             Threads.route("https://www.threads.com/@nasa/post/DePPcDfkc_a")
  end

  test "a carousel with videos stays an album, even with music" do
    music = media("DePPcDfkc_a")["text_app_music_info"]
    stub_pages(%{"Ddt7cL5EfUG" => Map.put(media("Ddt7cL5EfUG"), "text_app_music_info", music)})

    assert {:album, %Post{}} = Threads.route("https://www.threads.com/@zuck/post/Ddt7cL5EfUG")
  end

  test "posts without photos or videos are unsupported" do
    # A GIF post: logged out, Threads gives a placeholder image in the GIF's place.
    gif = %{
      "code" => "Cgif",
      "media_type" => 19,
      "caption" => nil,
      "giphy_media_info" => %{
        "images" => %{
          "fixed_height" => %{
            "url" => "https://static.cdninstagram.com/rsrc.php/v4/yr/r/xg_5YoVlvjp.gif",
            "width" => 160,
            "height" => 100
          }
        }
      },
      "user" => %{"username" => "someone"}
    }

    stub_pages(%{
      "Dd1MqfcG0aH" => media("Dd1MqfcG0aH"),
      "DeIqbp0lJAa" => media("DeIqbp0lJAa"),
      "Cgif" => gif
    })

    for url <- [
          "https://www.threads.com/@zuck/post/Dd1MqfcG0aH",
          "https://www.threads.com/@mosseri/post/DeIqbp0lJAa",
          "https://www.threads.com/@someone/post/Cgif"
        ] do
      assert Threads.route(url) ==
               {:error, Error.new(:unsupported, "This Threads post has no photos or videos")}
    end
  end

  test "posts Threads doesn't show are unavailable" do
    stub_pages(%{})

    assert Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSJ") ==
             {:error,
              Error.new(
                :unavailable,
                "This Threads post is private, deleted or not shown to logged-out visitors"
              )}
  end

  test "loads a page without the post again, then fails as transient" do
    stub_threads(&html(&1, shell()))

    assert Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSK") ==
             {:error,
              Error.new(
                :transient,
                "Could not load the Threads post (no post data in the post page)"
              )}

    for _attempt <- 1..3, do: assert_received({:threads_request, "GET", _path, _conn})
    refute_received {:threads_request, _method, _path, _conn}
  end

  test "a page that comes with the post on a later load is read" do
    {:ok, loads} = Agent.start_link(fn -> 0 end)

    stub_threads(fn conn ->
      if Agent.get_and_update(loads, &{&1, &1 + 1}) == 0,
        do: html(conn, shell()),
        else: html(conn, page(media("DeUWxGgjHSK")))
    end)

    assert {:album, %Post{}} = Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSK")
  end

  test "rate limiting fails as transient at once" do
    stub_threads(&Plug.Conn.send_resp(&1, 429, ""))

    assert Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSK") ==
             {:error,
              Error.new(:transient, "Threads is rate limiting requests, trying again later")}

    assert_received {:threads_request, "GET", _path, _conn}
    refute_received {:threads_request, _method, _path, _conn}
  end

  describe "share links" do
    test "are followed with one request that doesn't follow the redirect" do
      stub_threads(fn conn ->
        case conn.request_path do
          "/share/AbCdEf12_-/" ->
            assert Plug.Conn.get_req_header(conn, "user-agent") == ["curl/8.7.1"]

            InstagramFixtures.redirect(
              conn,
              "https://www.threads.com/@nasa/post/DeUWxGgjHSK?xmt=AQG0&slof=1"
            )

          "/@nasa/post/DeUWxGgjHSK" ->
            html(conn, page(media("DeUWxGgjHSK")))
        end
      end)

      assert {:album, %Post{code: "DeUWxGgjHSK"}} =
               Threads.route("https://threads.net/share/AbCdEf12_-?x=1")

      assert_received {:threads_request, "GET", "www.threads.com/share/AbCdEf12_-/", _conn}
      assert_received {:threads_request, "GET", "www.threads.com/@nasa/post/DeUWxGgjHSK", _conn}
      refute_received {:threads_request, _method, _path, _conn}
    end

    test "that answer with a page or redirect home have expired" do
      expired = {:error, Error.new(:unavailable, "This Threads link has expired or is invalid")}

      stub_threads(&html(&1, shell()))
      assert Threads.route("https://www.threads.com/share/AAAAAAAAAA/") == expired

      stub_threads(&InstagramFixtures.redirect(&1, "https://www.threads.com/"))
      assert Threads.route("https://www.threads.com/share/AAAAAAAAAA/") == expired
    end

    test "that can't be followed fail as transient" do
      for {stub, reason} <- [
            {&InstagramFixtures.redirect(&1, "/login?next=/share/x"),
             "redirected to the login page"},
            {&InstagramFixtures.redirect(&1, "https://evil.test/@a/post/DeUWxGgjHSK"),
             "redirected elsewhere"},
            {&Plug.Conn.send_resp(&1, 302, ""), "no redirect location"},
            {&Plug.Conn.send_resp(&1, 500, ""), "HTTP 500"}
          ] do
        stub_threads(stub)

        assert Threads.route("https://www.threads.com/share/AbCdEf12_-/") ==
                 {:error,
                  Error.new(:transient, "Could not open the Threads share link (#{reason})")}
      end
    end
  end

  describe "request/1" do
    test "has bounded timeouts, no automatic retries and the test plug" do
      request = Threads.request(url: "https://www.threads.com/")

      assert %{
               retry: false,
               redirect: false,
               receive_timeout: 15_000,
               request_timeout: 30_000,
               connect_options: [timeout: 15_000]
             } = request.options

      assert request.options.plug == {Req.Test, Threads}
    end

    test "never follows redirects, whatever the options say" do
      stub_threads(fn conn ->
        case conn.request_path do
          "/moved" -> InstagramFixtures.redirect(conn, "https://www.threads.com/elsewhere")
          "/elsewhere" -> Plug.Conn.send_resp(conn, 200, "followed")
        end
      end)

      request = Threads.request(url: "https://www.threads.com/moved", redirect: true)
      assert {:ok, %Req.Response{status: 302}} = Req.request(request)
    end
  end
end
