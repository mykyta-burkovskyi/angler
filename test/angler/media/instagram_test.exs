defmodule Angler.Media.InstagramTest do
  # Angler.Media.Instagram.route/3 up to the yt-dlp fallback, which
  # instagram_metadata_test.exs covers (it changes the application environment).
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures

  alias Angler.Media.{Error, Instagram}
  alias Angler.Media.Instagram.Post

  @moduletag :capture_log
  @moduletag :tmp_dir

  defp route(url, %{tmp_dir: dir}, opts \\ []), do: Instagram.route(url, dir, opts)

  test "does not touch the network for other links", context do
    stub_instagram(fn _conn -> flunk("unexpected request") end)

    for url <- [
          "https://www.tiktok.com/@a/video/1",
          "https://www.instagram.com/instagram/",
          "https://www.instagram.com/stories/instagram/1/"
        ] do
      assert route(url, context) == :not_instagram
    end
  end

  test "routes posts with photos or several items to the album download", context do
    stub_graphql(%{
      "DdwalmrkTSK" => graphql("DdwalmrkTSK"),
      "Ddwoj5kBk9X" => graphql("Ddwoj5kBk9X"),
      "Ddr-AMmDxqn" => graphql("Ddr-AMmDxqn")
    })

    assert {:album, %Post{code: "DdwalmrkTSK", items: [_, _, _]} = post} =
             route("https://www.instagram.com/p/DdwalmrkTSK/?img_index=2", context)

    assert post.webpage_url == "https://www.instagram.com/p/DdwalmrkTSK/"
    assert Post.title(post) =~ "we said yes"

    assert {:album, %Post{items: [%{type: :photo}]}} =
             route("https://instagr.am/p/Ddwoj5kBk9X/", context)

    # Three videos: sent as an album, not as the first video.
    assert {:album, %Post{items: [%{type: :video}, %{type: :video}, %{type: :video}]}} =
             route("https://www.instagram.com/reel/Ddr-AMmDxqn/", context)
  end

  test "sends a single video to yt-dlp with its canonical URL and the post text", context do
    stub_graphql(%{
      "Chunk8-jurw" => graphql("Chunk8-jurw"),
      "Cquiet" => graphql_answer(post([video()], code: "Cquiet", caption: nil))
    })

    assert {:ytdlp, "https://www.instagram.com/p/Chunk8-jurw/", %{title: title}} =
             route("https://www.instagram.com/instagram/reel/Chunk8-jurw/?igsh=abc", context)

    assert title =~ "Gingerton"

    assert route("https://www.instagram.com/reel/Cquiet/", context) ==
             {:ytdlp, "https://www.instagram.com/p/Cquiet/", %{title: nil}}
  end

  test "reads the post page when the GraphQL API gives up", context do
    stub_instagram(fn conn ->
      case conn.request_path do
        "/api/graphql" -> Req.Test.html(conn, "<html>no data</html>")
        "/p/DdwalmrkTSK/" -> Req.Test.html(conn, recorded("page_carousel_DdwalmrkTSK.html"))
      end
    end)

    assert {:album, %Post{code: "DdwalmrkTSK", items: [_, _, _]}} =
             route("https://www.instagram.com/p/DdwalmrkTSK/", context)

    for _attempt <- 1..3,
        do: assert_received({:instagram_request, "POST", "www.instagram.com/api/graphql", _conn})

    assert_received {:instagram_request, "GET", "www.instagram.com/p/DdwalmrkTSK/", _conn}
  end

  describe "without a cookies file (the test configuration)" do
    test "fails hidden posts at once", context do
      stub_graphql(%{
        "DdwalmrkTSX" => graphql("DdwalmrkTSX"),
        "B7" => recorded("graphql_gated_pk123.json")
      })

      assert route("https://www.instagram.com/p/DdwalmrkTSX/", context) ==
               {:error,
                Error.new(
                  :unavailable,
                  "This Instagram post is private, deleted or age-restricted"
                )}

      assert route("https://www.instagram.com/p/B7/", context) ==
               {:error, Error.new(:unavailable, "Not available in your region")}

      # Neither the page nor yt-dlp would see more.
      for _post <- 1..2, do: assert_received({:instagram_request, "POST", _path, _conn})
      refute_received {:instagram_request, _method, _path, _conn}
    end

    test "fails a post the page reports missing", context do
      stub_instagram(fn conn ->
        case conn.request_path do
          "/api/graphql" -> Plug.Conn.send_resp(conn, 500, "")
          _page -> Req.Test.html(conn, recorded("page_not_found_DdwalmrkTSX.html"))
        end
      end)

      assert {:error, %Error{kind: :unavailable}} =
               route("https://www.instagram.com/p/DdwalmrkTSX/", context)
    end

    test "retries later when Instagram rate limits, without further requests", context do
      stub_instagram(&Plug.Conn.send_resp(&1, 429, ""))

      assert route("https://www.instagram.com/p/DdwalmrkTSK/", context) ==
               {:error,
                Error.new(:transient, "Instagram is rate limiting requests, trying again later")}

      assert_received {:instagram_request, "POST", _path, _conn}
      refute_received {:instagram_request, _method, _path, _conn}
    end
  end

  describe "share links" do
    test "follow the redirect with one request, without cookies", context do
      stub_instagram(fn conn ->
        case conn.request_path do
          "/share/_a7bsO89b" ->
            redirect(conn, "https://www.instagram.com/p/Ddwoj5kBk9X/?igsh=MWx0c3l1")

          "/share/reel/_0ML8mSEs/" ->
            redirect(conn, "/reel/Chunk8-jurw/?igsh=X3cwMEp5TE9q", 301)

          "/api/graphql" ->
            {media_id, conn} = graphql_media_id(conn)

            code =
              Enum.find(
                ~w(Ddwoj5kBk9X Chunk8-jurw),
                &(Angler.Media.Instagram.Url.pk(&1) == media_id)
              )

            javascript(conn, graphql(code))
        end
      end)

      assert {:album, %Post{code: "Ddwoj5kBk9X"}} =
               route("https://www.instagram.com/share/_a7bsO89b", context)

      assert_received {:instagram_request, "GET", "www.instagram.com/share/_a7bsO89b", share}
      assert Plug.Conn.get_req_header(share, "user-agent") == ["curl/8.7.1"]
      assert Plug.Conn.get_req_header(share, "cookie") == []

      assert {:ytdlp, "https://www.instagram.com/p/Chunk8-jurw/", _meta} =
               route("https://instagram.com/share/reel/_0ML8mSEs/?igsh=x", context)
    end

    test "report expired links", context do
      stub_instagram(fn conn ->
        case conn.request_path do
          "/share/home" -> redirect(conn, "https://www.instagram.com/")
          "/share/shell" -> Req.Test.html(conn, "<html>Instagram</html>")
        end
      end)

      for token <- ~w(home shell) do
        assert route("https://www.instagram.com/share/#{token}", context) ==
                 {:error,
                  Error.new(:unavailable, "This Instagram link has expired or is invalid")}
      end
    end

    test "retry anything else", context do
      for {response, reason} <- [
            {&redirect(&1, "https://www.instagram.com/accounts/login/?next=%2Fshare%2Fx"),
             "redirected to the login page"},
            {&redirect(&1, "https://www.instagram.com/explore/"), "redirected elsewhere"},
            {&Plug.Conn.send_resp(&1, 302, ""), "no redirect location"},
            {&Plug.Conn.send_resp(&1, 429, ""), "HTTP 429"},
            {&Plug.Conn.send_resp(&1, 502, ""), "HTTP 502"},
            {&Req.Test.transport_error(&1, :closed), "network error (closed)"}
          ] do
        stub_instagram(response)

        assert route("https://www.instagram.com/share/p/BBFVaX2n1Y", context) ==
                 {:error,
                  Error.new(:transient, "Could not open the Instagram share link (#{reason})")}
      end
    end
  end
end
