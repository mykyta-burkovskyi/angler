defmodule Angler.Media.TikTokTest do
  use ExUnit.Case, async: true

  import Angler.TikTokFixtures

  alias Angler.Media.{Error, TikTok}
  alias Angler.Media.Ytdlp.Outcome
  alias Angler.Media.TikTok.Post

  @moduletag :capture_log

  describe "parse_url/1" do
    for {url, expected} <- [
          {"https://www.tiktok.com/@hullcity/photo/7553302113757990166",
           {:post, "7553302113757990166", :photo}},
          {"https://www.tiktok.com/@croatian_memes/video/7406655666472979745?lang=en",
           {:post, "7406655666472979745", :video}},
          {"https://tiktok.com/@some.user-name_1/video/123/", {:post, "123", :video}},
          {"https://m.tiktok.com/@x/photo/42", {:post, "42", :photo}},
          {"http://WWW.TikTok.com/@a/video/7", {:post, "7", :video}},
          {"https://www.tiktok.com/@/video/7449708266168274208",
           {:post, "7449708266168274208", :video}},
          {"https://www.tiktokv.com/share/video/7449708266168274208",
           {:post, "7449708266168274208", :video}},
          {"https://www.tiktok.com/embed/v2/99", {:post, "99", :video}},
          {"https://www.tiktok.com/embed/98", {:post, "98", :video}},
          {"https://vt.tiktok.com/ZSaVMnnpj/", {:short, "https://vt.tiktok.com/ZSaVMnnpj/"}},
          {"https://vm.tiktok.com/ZGdh4WUhr", {:short, "https://vm.tiktok.com/ZGdh4WUhr"}},
          {"http://vm.tiktok.com/ZGdh4WUhr/?_r=1", {:short, "https://vm.tiktok.com/ZGdh4WUhr/"}},
          {"https://www.tiktok.com/t/ZTR45GpSF/",
           {:short, "https://www.tiktok.com/t/ZTR45GpSF/"}},
          {"https://tiktok.com/t/ZTR45GpSF", {:short, "https://tiktok.com/t/ZTR45GpSF"}},
          {"https://www.tt.site/t/ZSbn1M6Yo/", {:short, "https://www.tt.site/t/ZSbn1M6Yo/"}},
          {"https://tt.site/t/ZSbn1M6Yo", {:short, "https://www.tt.site/t/ZSbn1M6Yo"}},
          {"https://www.tt.site/@doombreaker03/video/7694316974494534930",
           {:post, "7694316974494534930", :video}},
          {"https://www.tt.site/ZSbn1M6Yo/", :not_tiktok},
          {"https://www.tiktok.com/@hullcity", :not_tiktok},
          {"https://www.tiktok.com/music/original-sound-7547211051650157329", :not_tiktok},
          {"https://www.tiktok.com/", :not_tiktok},
          {"https://vm.tiktok.com/", :not_tiktok},
          {"https://www.tiktok.com.evil.test/@a/video/1", :not_tiktok},
          {"https://nottiktok.com/@a/video/1", :not_tiktok},
          {"https://www.youtube.com/watch?v=jNQXAC9IVRw", :not_tiktok},
          {"ftp://www.tiktok.com/@a/video/1", :not_tiktok},
          {"www.tiktok.com/@a/video/1", :not_tiktok},
          {"not a url", :not_tiktok}
        ] do
      test "#{url}" do
        assert TikTok.parse_url(unquote(url)) == unquote(Macro.escape(expected))
      end
    end
  end

  test "canonical_url/1 uses an empty user name, which the page and yt-dlp accept" do
    assert TikTok.canonical_url("7449708266168274208") ==
             "https://www.tiktok.com/@/video/7449708266168274208"
  end

  describe "resolve/1" do
    test "does not touch the network for other links" do
      stub_tiktok(fn _conn -> flunk("unexpected request") end)
      assert TikTok.resolve("https://www.youtube.com/watch?v=jNQXAC9IVRw") == :not_tiktok
      assert TikTok.resolve("https://www.tiktok.com/@hullcity") == :not_tiktok
    end

    test "reads a recorded slideshow page into a post" do
      stub_tiktok(fn conn -> Req.Test.html(conn, recorded_page("slideshow_page")) end)

      assert {:ok, {:slideshow, %Post{} = post}} =
               TikTok.resolve("https://www.tiktok.com/@natgeo/photo/7466527368044088619")

      # Always the /video/ page: the /photo/ page has no post data.
      assert_received {:tiktok_request, "GET", "www.tiktok.com/@/video/7466527368044088619", conn}

      assert Plug.Conn.get_req_header(conn, "user-agent") == [
               "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
                 "Chrome/140.0.0.0 Safari/537.36"
             ]

      assert Plug.Conn.get_req_header(conn, "accept-language") == ["en-US,en;q=0.9"]
      assert Plug.Conn.get_req_header(conn, "cookie") == []

      assert %Post{
               id: "7466527368044088619",
               author: "natgeo",
               audio_url:
                 "https://sf58-ies-music-sg.tiktokcdn.com/obj/tos-alisg-ve-2774/oA8t5Cn8IQN3JhMkTffNBBgnNG6z1IINZszNtt",
               audio_duration: 55.4,
               webpage_url: "https://www.tiktok.com/@natgeo/photo/7466527368044088619",
               title: "For centuries, there was a gap" <> _
             } = post

      assert length(post.images) == 4
      assert [%{urls: [first, second], width: 2048, height: 1366} | _] = post.images

      assert first =~
               ~r{^https://p19-common-sign\.tiktokcdn\.com/.*f2c9c17cbd4f4edcb9c5a9c912e727fb}

      assert second =~ ~r{^https://p16-common-sign\.tiktokcdn\.com/}
    end

    test "reads a slideshow without sound" do
      stub_tiktok(fn conn -> Req.Test.html(conn, recorded_page("silent_slideshow_page")) end)

      assert {:ok, {:slideshow, %Post{} = post}} =
               TikTok.resolve("https://www.tiktok.com/@itsevykins/photo/7367130722806648106")

      assert post.audio_url == nil
      assert post.audio_duration == 53.915
      assert length(post.images) == 12

      assert Enum.map(post.images, &{&1.width, &1.height}) |> Enum.take(2) == [
               {2160, 2880},
               {1686, 2249}
             ]

      assert post.title == "#cat"
    end

    test "sends regular videos to yt-dlp with the canonical URL" do
      stub_tiktok(fn conn ->
        Req.Test.html(conn, page(detail(video_item("7449708266168274208"))))
      end)

      assert TikTok.resolve("https://www.tiktok.com/@memezar/video/7449708266168274208") ==
               {:ok, :video, "https://www.tiktok.com/@/video/7449708266168274208"}
    end

    test "maps TikTok status codes to errors" do
      for {code, message} <- [
            {10204, "This TikTok post was deleted"},
            {10222, "This TikTok post is private"},
            {10216, "This TikTok post is private"},
            {10101, "This TikTok post is not available (status 10101)"}
          ] do
        stub_tiktok(fn conn -> Req.Test.html(conn, page(status_detail(code))) end)

        assert {:error, %Error{kind: :unavailable, message: ^message}} =
                 TikTok.resolve("https://www.tiktok.com/@ughuwhguweghw/video/1")
      end
    end

    test "reports a redirect to the login page" do
      stub_tiktok(fn conn -> redirect(conn, "https://www.tiktok.com/login?redirect_url=x") end)

      assert {:error,
              %Error{kind: :unavailable, message: "TikTok requires login to view this post"}} =
               TikTok.resolve("https://www.tiktok.com/@a/photo/5")
    end

    test "follows photo and video short links with one request" do
      stub_tiktok(fn conn ->
        case conn.host <> conn.request_path do
          "vt.tiktok.com/ZSaVMnnpj/" ->
            redirect(conn, "https://www.tiktok.com/@/photo/7587154199058795796?_t=x&_r=1")

          "www.tiktok.com/t/ZTvideo/" ->
            redirect(conn, "https://www.tiktok.com/@/video/7449708266168274208?_r=1", 301)

          "www.tiktok.com/@/video/7587154199058795796" ->
            Req.Test.html(conn, page(detail(slideshow_item("7587154199058795796", 7))))

          "www.tiktok.com/@/video/7449708266168274208" ->
            Req.Test.html(conn, page(detail(video_item("7449708266168274208"))))
        end
      end)

      assert {:ok, {:slideshow, %Post{id: "7587154199058795796", images: images}}} =
               TikTok.resolve("https://vt.tiktok.com/ZSaVMnnpj/")

      assert length(images) == 7
      assert_received {:tiktok_request, "GET", "vt.tiktok.com/ZSaVMnnpj/", short}
      assert Plug.Conn.get_req_header(short, "user-agent") == ["facebookexternalhit/1.1"]

      assert TikTok.resolve("https://www.tiktok.com/t/ZTvideo/") ==
               {:ok, :video, "https://www.tiktok.com/@/video/7449708266168274208"}
    end

    test "follows TikTok's tt.site short links" do
      stub_tiktok(fn conn ->
        case conn.host <> conn.request_path do
          "www.tt.site/t/ZSbn1M6Yo/" ->
            redirect(
              conn,
              "https://www.tiktok.com/@doombreaker03/video/7694316974494534930?_r=1&_t=x",
              301
            )

          "www.tiktok.com/@/video/7694316974494534930" ->
            Req.Test.html(conn, page(detail(video_item("7694316974494534930"))))
        end
      end)

      assert TikTok.route("https://www.tt.site/t/ZSbn1M6Yo/") ==
               {:ytdlp, "https://www.tiktok.com/@/video/7694316974494534930"}

      assert_received {:tiktok_request, "GET", "www.tt.site/t/ZSbn1M6Yo/", _conn}
    end

    test "reports expired short links" do
      stub_tiktok(fn conn ->
        case conn.request_path do
          "/ZGdh4WUhr" -> redirect(conn, "https://www.tiktok.com/?_r=1")
          "/gone" -> Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      for url <- ["https://vm.tiktok.com/ZGdh4WUhr", "https://vm.tiktok.com/gone"] do
        assert TikTok.resolve(url) ==
                 {:error, Error.new(:unavailable, "This TikTok link has expired or is invalid")}
      end

      assert_received {:tiktok_request, "GET", "vm.tiktok.com/ZGdh4WUhr", _conn}
      refute_received {:tiktok_request, _method, "www.tiktok.com" <> _path, _conn}
    end

    test "hands short links to other TikTok pages to yt-dlp" do
      stub_tiktok(fn conn -> redirect(conn, "/@hullcity?lang=en") end)

      assert TikTok.resolve("https://vm.tiktok.com/ZMprofile") ==
               {:ok, :video, "https://vm.tiktok.com/@hullcity?lang=en"}
    end

    test "solves the proof-of-work challenge and loads the page again with its cookies" do
      stub_tiktok(fn conn ->
        case Plug.Conn.get_req_header(conn, "cookie") do
          [] -> Req.Test.html(conn, challenge_page(57))
          [_cookie] -> Req.Test.html(conn, page(detail(video_item("1"))))
        end
      end)

      assert TikTok.resolve("https://www.tiktok.com/@a/video/1") ==
               {:ok, :video, "https://www.tiktok.com/@/video/1"}

      assert_received {:tiktok_request, "GET", _path, first}
      assert Plug.Conn.get_req_header(first, "cookie") == []
      assert_received {:tiktok_request, "GET", _path, second}
      assert [cookie] = Plug.Conn.get_req_header(second, "cookie")

      assert ["_wafchallengeid=" <> answer, "waforiginalreid=rs-value-42"] =
               String.split(cookie, "; ")

      assert %{"d" => d} = answer |> Base.decode64!() |> Jason.decode!()
      assert Base.decode64!(d) == "57"
    end

    test "retries three times, then reports a transient error" do
      for response <- [
            &Req.Test.transport_error(&1, :econnrefused),
            &Plug.Conn.send_resp(&1, 403, "Forbidden"),
            &Req.Test.html(&1, "<html><body>Something else</body></html>"),
            &Req.Test.html(&1, ~s(<div id="cs" class="not base64!"></div>)),
            &Req.Test.html(&1, page(%{"statusCode" => 0, "itemInfo" => %{}})),
            &redirect(&1, "https://www.tiktok.com/somewhere")
          ] do
        stub_tiktok(response)

        assert {:error, %Error{kind: :transient, message: "Could not load the TikTok post" <> _}} =
                 TikTok.resolve("https://www.tiktok.com/@a/photo/1")

        for _attempt <- 1..3, do: assert_received({:tiktok_request, "GET", _path, _conn})
        refute_received {:tiktok_request, _method, _path, _conn}
      end
    end

    test "recovers when a later attempt works" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      stub_tiktok(fn conn ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 -> Plug.Conn.send_resp(conn, 503, "")
          _later -> Req.Test.html(conn, page(detail(video_item("3"))))
        end
      end)

      assert {:ok, :video, _url} = TikTok.resolve("https://www.tiktok.com/@a/video/3")
      assert Agent.get(attempts, & &1) == 2
    end

    test "a failing short link is a transient error" do
      stub_tiktok(&Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{kind: :transient, message: "Could not reach TikTok: " <> _}} =
               TikTok.resolve("https://vt.tiktok.com/ZSaVMnnpj/")

      assert_received {:tiktok_request, "GET", "vt.tiktok.com/ZSaVMnnpj/", _conn}
      refute_received {:tiktok_request, _method, _path, _conn}
    end
  end

  describe "route/1" do
    test "sends videos and other links to yt-dlp, photo posts to the slideshow" do
      stub_tiktok(fn conn ->
        case conn.request_path do
          "/@/video/1" -> Req.Test.html(conn, page(detail(video_item("1"))))
          "/@/video/2" -> Req.Test.html(conn, page(detail(slideshow_item("2", 3))))
        end
      end)

      assert TikTok.route("https://www.tiktok.com/@a/video/1") ==
               {:ytdlp, "https://www.tiktok.com/@/video/1"}

      assert {:slideshow, %Post{id: "2"}} = TikTok.route("https://www.tiktok.com/@a/video/2")
      assert TikTok.route("https://example.com/v.mp4") == {:ytdlp, "https://example.com/v.mp4"}
    end

    test "falls back to yt-dlp with the original link when the page can't be read" do
      stub_tiktok(&Plug.Conn.send_resp(&1, 500, ""))
      url = "https://www.tiktok.com/@memezar/video/7449708266168274208"
      assert TikTok.route(url) == {:ytdlp, url}

      stub_tiktok(&Req.Test.transport_error(&1, :closed))

      assert TikTok.route("https://vm.tiktok.com/ZMabc/") ==
               {:ytdlp, "https://vm.tiktok.com/ZMabc/"}
    end

    test "keeps the error for photo posts, which yt-dlp does not support" do
      stub_tiktok(fn conn ->
        case conn.host do
          "vt.tiktok.com" -> redirect(conn, "https://www.tiktok.com/@/photo/9")
          "www.tiktok.com" -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:error, %Error{kind: :transient}} =
               TikTok.route("https://www.tiktok.com/@a/photo/9")

      assert {:error, %Error{kind: :transient}} = TikTok.route("https://vt.tiktok.com/ZSphoto/")
    end

    test "keeps final errors" do
      stub_tiktok(fn conn -> Req.Test.html(conn, page(status_detail(10204))) end)

      assert {:error, %Error{kind: :unavailable, message: "This TikTok post was deleted"}} =
               TikTok.route("https://www.tiktok.com/@a/video/1")

      stub_tiktok(fn conn -> redirect(conn, "https://www.tiktok.com/?_r=1") end)

      assert {:error, %Error{kind: :unavailable}} =
               TikTok.route("https://vm.tiktok.com/ZGdh4WUhr")

      # Without a yt-dlp cookies file (the test configuration), yt-dlp can't do better.
      stub_tiktok(fn conn -> Req.Test.html(conn, page(status_detail(10222))) end)

      assert {:error, %Error{kind: :unavailable}} =
               TikTok.route("https://www.tiktok.com/@a/video/1")
    end
  end

  describe "Post" do
    test "from_item/2 reads images in display order and tolerates missing fields" do
      item = %{
        "desc" => "  ",
        "author" => %{"uniqueId" => "someone"},
        "imagePost" => %{
          "images" => [
            %{"imageURL" => %{"urlList" => ["https://a/1", "https://b/1"]}, "imageWidth" => 10},
            %{"imageURL" => %{"urlList" => []}},
            %{"imageURL" => %{"urlList" => [nil, "https://a/3"]}, "imageHeight" => 0},
            "garbage"
          ]
        },
        "music" => %{"playUrl" => "", "duration" => 12}
      }

      assert Post.slideshow?(item)

      assert Post.from_item(item, "5") == %Post{
               id: "5",
               images: [
                 %{urls: ["https://a/1", "https://b/1"], width: 10, height: nil},
                 %{urls: ["https://a/3"], width: nil, height: nil}
               ],
               audio_url: nil,
               audio_duration: 12.0,
               title: "Slideshow by @someone",
               author: "someone",
               webpage_url: "https://www.tiktok.com/@someone/photo/5"
             }

      assert %Post{images: [], title: nil, audio_duration: nil} =
               Post.from_item(%{"imagePost" => "odd", "music" => []}, "6")
    end

    test "slideshow?/1 needs at least one image" do
      refute Post.slideshow?(video_item("1"))
      refute Post.slideshow?(%{"imagePost" => %{"images" => []}})
      assert Post.slideshow?(slideshow_item("1", 1))
    end
  end

  # yt-dlp is challenged on every TikTok run and gets a 403 on about 3 in 8; those
  # must stay retryable (TikTok videos still go through yt-dlp).
  test "yt-dlp's TikTok 403 errors are transient" do
    for message <- [
          "[TikTok] 7449708266168274208: Unable to download webpage: HTTP Error 403: Forbidden " <>
            "(caused by <HTTPError 403: Forbidden>)",
          "unable to download video data: HTTP Error 403: Forbidden"
        ] do
      assert Outcome.classify(message) == :transient
    end
  end
end
