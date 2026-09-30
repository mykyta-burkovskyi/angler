defmodule Angler.Media.InstagramMetadataTest do
  # Angler.Media.Instagram.route/3 falling back to yt-dlp's metadata (the fake yt-dlp
  # in test/fixtures/media/fake-yt-dlp), with and without a cookies file. Changes
  # the Angler.Media application environment.
  use ExUnit.Case, async: false

  import Angler.InstagramFixtures

  alias Angler.Media
  alias Angler.Media.{Error, Instagram}
  alias Angler.Media.Instagram.Post

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    metadata = Path.join(tmp_dir, "metadata")
    File.mkdir_p!(metadata)

    for {code, name} <- [
          {"DduKfFmDxsG", "ytdlp_carousel_photo_video_DduKfFmDxsG.jsonl"},
          {"Ddwoj5kBk9X", "ytdlp_photo_Ddwoj5kBk9X.jsonl"}
        ],
        do: File.cp!(fixture_path(name), Path.join(metadata, code <> ".jsonl"))

    # A reel: the video entry of the carousel, on its own.
    [_photo, video] = ytdlp_entries("DduKfFmDxsG")
    reel = video |> Map.drop(~w(playlist_index playlist_id)) |> Map.put("id", "Creel")
    File.write!(Path.join(metadata, "Creel.jsonl"), Jason.encode!(reel) <> "\n")

    # A post whose entries have nothing to download.
    File.write!(Path.join(metadata, "Cnothing.jsonl"), ~s({"id": "Cnothing", "formats": []}\n))

    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    put_media_env(
      data_dir: Path.join(tmp_dir, "data"),
      ytdlp_path: ytdlp,
      cookies_file: nil,
      ytdlp_update_channel: nil,
      allow_private_networks: false
    )

    %{dir: dir, cookies: Path.join(tmp_dir, "cookies.txt")}
  end

  defp put_media_env(values) do
    Application.put_env(
      :angler,
      Media,
      Keyword.merge(Application.get_env(:angler, Media), values)
    )
  end

  defp use_cookies(path) do
    File.write!(path, ".instagram.com\tTRUE\t/\tTRUE\t0\tsessionid\tS3SSION\n")
    put_media_env(cookies_file: path)
  end

  # The URL the fake yt-dlp was called with and whether it got cookies, or nil.
  defp ytdlp_run(dir) do
    case File.read(Path.join(dir, "args.txt")) do
      {:ok, args} ->
        args = String.split(args, "\n", trim: true)
        %{url: List.last(args), cookies?: "--cookies" in args}

      {:error, :enoent} ->
        nil
    end
  end

  defp refuse_everything, do: stub_instagram(&Plug.Conn.send_resp(&1, 500, ""))

  test "asks yt-dlp when neither the GraphQL API nor the post page can be read", %{dir: dir} do
    refuse_everything()

    assert {:album, %Post{code: "DduKfFmDxsG", items: [photo, video]} = post} =
             Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/?img_index=1", dir)

    assert %{type: :photo} = photo
    assert %{type: :video} = video
    assert post.caption =~ "Ready to post your next photo dump?"
    assert post.webpage_url == "https://www.instagram.com/p/DduKfFmDxsG/"

    assert ytdlp_run(dir) == %{url: "https://www.instagram.com/p/DduKfFmDxsG/", cookies?: false}
    assert_received {:instagram_request, "GET", "www.instagram.com/p/DduKfFmDxsG/", _page}

    assert {:album, %Post{items: [%{type: :photo}]}} =
             Instagram.route("https://www.instagram.com/p/Ddwoj5kBk9X/", dir)
  end

  test "sends a single video found by yt-dlp to the yt-dlp download", %{dir: dir} do
    refuse_everything()

    assert {:ytdlp, "https://www.instagram.com/p/Creel/", %{title: title}} =
             Instagram.route("https://www.instagram.com/reel/Creel/", dir)

    assert title =~ "Ready to post your next photo dump?"
  end

  test "asks yt-dlp when Instagram's data has no items it can read", %{dir: dir} do
    broken = post([%{"media_type" => 2, "video_versions" => []}], code: "DduKfFmDxsG")
    stub_graphql(%{"DduKfFmDxsG" => graphql_answer(broken)})

    assert {:album, %Post{items: [_, _]}} =
             Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)
  end

  describe "with a cookies file" do
    setup %{cookies: cookies} do
      use_cookies(cookies)
    end

    test "asks yt-dlp (with the cookies) for posts hidden from logged-out visitors", %{dir: dir} do
      for answer <- [graphql("DdwalmrkTSX"), recorded("graphql_gated_pk123.json")] do
        stub_graphql(%{"DduKfFmDxsG" => answer})
        File.rm(Path.join(dir, "args.txt"))

        assert {:album, %Post{code: "DduKfFmDxsG"}} =
                 Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)

        assert %{cookies?: true} = ytdlp_run(dir)

        # Instagram's own requests never carry the cookies, and the page is not tried.
        assert_received {:instagram_request, "POST", _path, conn}
        assert Plug.Conn.get_req_header(conn, "cookie") == []
        refute_received {:instagram_request, _method, _path, _conn}
      end
    end

    test "asks yt-dlp when Instagram rate limits logged-out requests", %{dir: dir} do
      stub_instagram(&Plug.Conn.send_resp(&1, 429, ""))

      assert {:album, %Post{}} = Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)
      assert %{cookies?: true} = ytdlp_run(dir)
      assert_received {:instagram_request, "POST", _path, _conn}
      refute_received {:instagram_request, _method, _path, _conn}
    end

    test "reports yt-dlp's errors", %{dir: dir} do
      stub_graphql(%{
        "private" => graphql("DdwalmrkTSX"),
        "rate-limited" => graphql("DdwalmrkTSX")
      })

      assert {:error, %Error{kind: :unavailable, message: message}} =
               Instagram.route("https://www.instagram.com/p/private/", dir)

      assert message =~ "only available for registered users who follow this account"

      assert {:error, %Error{kind: :transient}} =
               Instagram.route("https://www.instagram.com/p/rate-limited/", dir)
    end
  end

  test "retries a post yt-dlp found nothing in, until the last attempt", %{dir: dir} do
    refuse_everything()
    url = "https://www.instagram.com/p/no-video/"

    assert {:error, %Error{kind: :transient, message: message}} =
             Instagram.route(url, dir, final_attempt: false)

    assert message == "Could not load the Instagram post (No video found at this link)"

    assert {:error, %Error{kind: :unavailable, message: ^message}} =
             Instagram.route(url, dir, final_attempt: true)
  end

  test "fails a post whose yt-dlp entries have nothing to download", %{dir: dir} do
    refuse_everything()

    assert Instagram.route("https://www.instagram.com/p/Cnothing/", dir) ==
             {:error, Error.new(:unsupported, "This Instagram post has no photos or videos")}
  end
end
