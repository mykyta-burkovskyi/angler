defmodule Angler.Media.Instagram.MediaInfoTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures
  import Angler.InstagramMusicFixtures
  import ExUnit.CaptureLog

  alias Angler.Media.Cookies
  alias Angler.Media.Instagram.{GraphQL, MediaInfo, Page}

  @code "DdlJg0lFG8-"
  @pk "3991638482632339262"
  @path "/api/v1/media/3991638482632339262/info/"

  defp cookies(opts \\ []), do: Cookies.parse(cookies_text(opts))

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  # Asserts that exactly one request was made: the media info GET.
  defp assert_one_request do
    assert_received {:instagram_request, "GET", "www.instagram.com" <> @path, conn}
    refute_received {:instagram_request, _method, _path, _conn}
    conn
  end

  test "url/1 is the media info URL of the post's media id" do
    assert MediaInfo.url(@code) == "https://www.instagram.com/api/v1/media/#{@pk}/info/"
    assert info_path(@code) == @path
  end

  test "asks for the post with the Instagram session and the headers the website sends" do
    stub_instagram(&json(&1, media_info(@code)))

    assert {:ok, %{"code" => @code, "pk" => @pk, "music_metadata" => %{}}} =
             MediaInfo.fetch(@code, cookies())

    conn = assert_one_request()

    # Only the Instagram cookies, not the TikTok one.
    assert [cookie] = header(conn, "cookie")

    assert MapSet.new(String.split(cookie, "; ")) ==
             MapSet.new(~w(sessionid=S3SSION csrftoken=CSRF7))

    assert header(conn, "x-csrftoken") == ["CSRF7"]
    assert header(conn, "x-ig-app-id") == ["936619743392459"]
    assert header(conn, "x-asbd-id") == ["359341"]
    assert header(conn, "sec-fetch-site") == ["same-origin"]
    assert header(conn, "referer") == ["https://www.instagram.com/"]
    assert [user_agent] = header(conn, "user-agent")
    assert user_agent =~ "Chrome/"
  end

  test "passes for the same browser and web app as the logged-out requests" do
    stub_instagram(fn conn ->
      case conn.request_path do
        "/api/graphql" -> javascript(conn, graphql(@code))
        "/api/v1/" <> _rest -> json(conn, media_info(@code))
        _page -> Req.Test.html(conn, "<html></html>")
      end
    end)

    assert {:ok, _media} = GraphQL.fetch(@code, [])
    assert {:gave_up, _reason} = Page.fetch(@code)
    assert {:ok, _media} = MediaInfo.fetch(@code, cookies())

    assert_received {:instagram_request, "POST", "www.instagram.com/api/graphql", graphql}
    assert_received {:instagram_request, "GET", "www.instagram.com/p/" <> _code, page}
    info = assert_one_request()

    for name <- ~w(user-agent x-ig-app-id x-asbd-id) do
      assert [_value] = header(info, name)
      assert header(info, name) == header(graphql, name)
    end

    assert header(page, "user-agent") == header(info, "user-agent")
  end

  test "sends no x-csrftoken header without a csrftoken cookie" do
    stub_instagram(&json(&1, media_info(@code)))

    assert {:ok, _media} = MediaInfo.fetch(@code, cookies(csrf: nil))

    conn = assert_one_request()
    assert header(conn, "cookie") == ["sessionid=S3SSION"]
    assert header(conn, "x-csrftoken") == []
  end

  test "makes no request without an Instagram session" do
    stub_instagram(&json(&1, media_info(@code)))

    for cookies <- [
          cookies(instagram: false),
          cookies(expires: 1_000_000_000),
          cookies(session: ""),
          []
        ] do
      assert MediaInfo.fetch(@code, cookies) == {:error, :no_session}
    end

    refute_received {:instagram_request, _method, _path, _conn}
  end

  defp redirect_to(location), do: &redirect(&1, location)

  defp error_answer(status, answer), do: &json(&1, answer, status)

  defp classifications do
    other_post =
      Jason.decode!(media_info(@code))["items"]
      |> hd()
      |> Map.merge(%{"pk" => "1", "code" => "C1"})

    please_wait = %{
      "message" => "Please wait a few minutes before you try again.",
      "require_login" => true,
      "status" => "fail"
    }

    [
      {&json(&1, media_info_answer(%{"pk" => String.to_integer(@pk), "media_type" => 1})),
       {:ok, %{"pk" => String.to_integer(@pk), "media_type" => 1}}},
      {&json(&1, media_info_answer(%{"pk" => "1", "code" => @code})),
       {:ok, %{"pk" => "1", "code" => @code}}},
      {&json(&1, ~s({"items":[],"num_results":0,"status":"ok"})), {:error, :missing}},
      {&json(&1, media_info_answer(other_post)),
       {:error, {:unexpected, "the answer is about another post"}}},
      {&Req.Test.html(&1, "<!DOCTYPE html><html>Instagram</html>"),
       {:error, {:unexpected, "the answer is not JSON"}}},
      {&json(&1, "{}"), {:error, {:unexpected, "unexpected answer"}}},
      {&json(&1, ~s({"items":{}})), {:error, {:unexpected, "unexpected answer"}}},
      {&json(&1, "[]"), {:error, {:unexpected, "unexpected answer"}}},
      {&json(&1, please_wait), {:error, {:rate_limited, "HTTP 200, please wait"}}},
      {&json(&1, %{"message" => "login_required", "status" => "fail"}),
       {:error, {:login_rejected, "HTTP 200, login required"}}},
      {redirect_to("https://www.instagram.com/accounts/login/?next=%2Fapi%2Fv1%2Fmedia%2F"),
       {:error, {:login_rejected, "redirected to the login page"}}},
      {redirect_to("/accounts/login/"),
       {:error, {:login_rejected, "redirected to the login page"}}},
      {redirect_to("https://www.instagram.com/"),
       {:error, {:login_rejected, "redirected to the login page"}}},
      {redirect_to("https://www.instagram.com"),
       {:error, {:login_rejected, "redirected to the login page"}}},
      {redirect_to("https://www.instagram.com/challenge/?next=/api/v1/media/"),
       {:error, {:login_rejected, "redirected to a checkpoint"}}},
      {redirect_to("/accounts/suspended/?next=%2F"),
       {:error, {:login_rejected, "redirected to a checkpoint"}}},
      {redirect_to("https://www.instagram.com/p/#{@code}/"),
       {:error, {:unexpected, "redirected with HTTP 302"}}},
      {&Plug.Conn.send_resp(&1, 302, ""), {:error, {:unexpected, "redirected with HTTP 302"}}},
      {error_answer(401, %{"message" => "", "require_login" => true, "status" => "fail"}),
       {:error, {:login_rejected, "HTTP 401, login required"}}},
      {&Plug.Conn.send_resp(&1, 401, ""),
       {:error, {:login_rejected, "HTTP 401, login required"}}},
      {error_answer(403, %{"message" => "login_required", "status" => "fail"}),
       {:error, {:login_rejected, "HTTP 403, login required"}}},
      {error_answer(400, %{
         "message" => "checkpoint_required",
         "checkpoint_url" => "/challenge/x/"
       }), {:error, {:login_rejected, "HTTP 400, checkpoint_required"}}},
      {error_answer(400, %{"message" => "challenge_required", "challenge" => %{"url" => "/x"}}),
       {:error, {:login_rejected, "HTTP 400, challenge_required"}}},
      {error_answer(400, %{"message" => "Verify it's you", "challenge" => %{"url" => "/x"}}),
       {:error, {:login_rejected, "HTTP 400, checkpoint_required"}}},
      {error_answer(400, %{
         "message" => "feedback_required",
         "spam" => true,
         "feedback_message" => "Try Again Later"
       }), {:error, {:rate_limited, "HTTP 400, feedback_required"}}},
      {error_answer(400, please_wait), {:error, {:rate_limited, "HTTP 400, please wait"}}},
      {error_answer(401, please_wait), {:error, {:rate_limited, "HTTP 401, please wait"}}},
      {&Plug.Conn.send_resp(&1, 429, ""), {:error, {:rate_limited, "HTTP 429"}}},
      {&Plug.Conn.send_resp(&1, 404, ""), {:error, :missing}},
      {error_answer(400, %{"message" => "Media not found or unavailable", "status" => "fail"}),
       {:error, :missing}},
      {error_answer(400, %{"message" => "Invalid media_id 1", "status" => "fail"}),
       {:error, :missing}},
      {error_answer(403, %{"message" => "something else", "status" => "fail"}),
       {:error, {:unexpected, "HTTP 403"}}},
      {&Plug.Conn.send_resp(&1, 400, "<html></html>"), {:error, {:unexpected, "HTTP 400"}}},
      {&Plug.Conn.send_resp(&1, 408, ""), {:error, {:unreachable, "HTTP 408"}}},
      {&Plug.Conn.send_resp(&1, 500, ""), {:error, {:unreachable, "HTTP 500"}}},
      {error_answer(503, please_wait), {:error, {:unreachable, "HTTP 503"}}},
      {&Plug.Conn.send_resp(&1, 204, ""), {:error, {:unexpected, "HTTP 204"}}},
      {&Req.Test.transport_error(&1, :timeout),
       {:error, {:unreachable, "network error (timeout)"}}}
    ]
  end

  test "classifies Instagram's answers, one request each, never following redirects" do
    for {response, expected} <- classifications() do
      stub_instagram(fn conn ->
        # A redirect target would show up as a second request.
        if conn.request_path == @path, do: response.(conn), else: json(conn, media_info(@code))
      end)

      assert MediaInfo.fetch(@code, cookies()) == expected
      assert_one_request()
    end
  end

  test "neither logs nor returns the cookie values" do
    log =
      capture_log(fn ->
        results =
          for {response, _expected} <- classifications() do
            stub_instagram(response)
            MediaInfo.fetch(@code, cookies())
          end

        refute inspect(results, limit: :infinity) =~ "S3SSION"
        refute inspect(results, limit: :infinity) =~ "CSRF7"
      end)

    refute log =~ "S3SSION"
    refute log =~ "CSRF7"
  end
end
