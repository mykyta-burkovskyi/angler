defmodule Angler.Media.InstagramNetworkTest do
  # Live Instagram posts through Angler.Media.Instagram (real Instagram and its CDN;
  # the yt-dlp metadata tests also need yt-dlp in PATH). Excluded by default; run with:
  #
  #   mix test test/angler/media/instagram_network_test.exs --include network
  #
  # Not async: talks to Instagram without the Req.Test stub of the test configuration.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Error, Instagram, Ytdlp}
  alias Angler.Media.Instagram.{GraphQL, Page, Post}

  @moduletag :network
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(5)

  @ytdlp System.find_executable("yt-dlp")

  setup %{tmp_dir: tmp_dir} do
    original = Application.get_env(:angler, Instagram)
    original_media = Application.get_env(:angler, Media)

    on_exit(fn ->
      Application.put_env(:angler, Instagram, original)
      Application.put_env(:angler, Media, original_media)
    end)

    Application.put_env(:angler, Instagram, [])

    Application.put_env(
      :angler,
      Media,
      Keyword.merge(original_media,
        data_dir: Path.join(tmp_dir, "data"),
        ytdlp_path: @ytdlp || "yt-dlp",
        cookies_file: nil,
        ytdlp_update_channel: nil
      )
    )

    :ok
  end

  defp items(%Post{items: items}), do: Enum.map(items, & &1.type)

  # The first URL of every item is on Instagram's CDN and serves the media.
  defp assert_downloadable(%Post{items: items}) do
    for %{type: type, urls: [url | _]} <- items do
      assert %URI{scheme: "https", host: host} = URI.parse(url)
      assert String.ends_with?(host, [".cdninstagram.com", ".fbcdn.net"])

      assert {:ok, %Req.Response{status: 200} = response} =
               Req.request(Instagram.request(url: url, decode_body: false))

      [content_type] = Req.Response.get_header(response, "content-type")
      assert content_type == if(type == :photo, do: "image/jpeg", else: "video/mp4")
    end
  end

  test "routes photo posts and carousels to albums, reels to yt-dlp", %{tmp_dir: dir} do
    assert {:album, %Post{} = carousel} =
             Instagram.route("https://www.instagram.com/p/DdwalmrkTSK/?img_index=2", dir)

    assert items(carousel) == [:photo, :photo, :photo]
    assert carousel.caption =~ "we said yes"
    assert_downloadable(carousel)

    assert {:album, %Post{} = mixed} =
             Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)

    assert items(mixed) == [:photo, :video]
    assert [_photo, %{duration: duration}] = mixed.items
    assert_in_delta duration, 17.9, 0.1
    assert_downloadable(mixed)

    assert {:album, %Post{} = photo} = Instagram.route("https://instagr.am/p/Ddwoj5kBk9X/", dir)
    assert [%{type: :photo, width: 2000, height: 2500}] = photo.items
    assert_downloadable(photo)

    assert {:ytdlp, "https://www.instagram.com/p/Chunk8-jurw/", %{title: title}} =
             Instagram.route("https://www.instagram.com/reel/Chunk8-jurw/", dir)

    assert title =~ "Gingerton"

    assert Instagram.route("https://www.instagram.com/p/DdwalmrkTSX/", dir) ==
             {:error,
              Error.new(:unavailable, "This Instagram post is private, deleted or age-restricted")}
  end

  test "follows share links", %{tmp_dir: dir} do
    assert {:album, %Post{code: "DEff-OiJg6-"}} =
             Instagram.route("https://www.instagram.com/share/_a7bsO89b", dir)
  end

  test "reads the same post from the GraphQL API and the post page" do
    assert {:ok, %{"code" => "DdwalmrkTSK"} = from_api} = GraphQL.fetch("DdwalmrkTSK", [1_000])
    assert {:ok, %{"code" => "DdwalmrkTSK"} = from_page} = Page.fetch("DdwalmrkTSK")

    assert {:ok, api_post} = Post.from_media(from_api)
    assert {:ok, page_post} = Post.from_media(from_page)
    assert items(api_post) == items(page_post)
    assert api_post.caption == page_post.caption

    assert Page.fetch("DdwalmrkTSX") == :missing
  end

  describe "yt-dlp metadata" do
    if is_nil(@ytdlp), do: @describetag(skip: "yt-dlp is not in PATH")

    test "reads carousels and single photos through the egress proxy", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "entry")
      File.mkdir_p!(dir)

      assert {:ok, entries} = Ytdlp.metadata("https://www.instagram.com/p/DduKfFmDxsG/", dir)
      assert {:ok, %Post{} = mixed} = Post.from_ytdlp(entries)
      assert items(mixed) == [:photo, :video]
      assert mixed.caption =~ "Ready to post your next photo dump?"
      assert_downloadable(mixed)

      assert {:ok, entries} = Ytdlp.metadata("https://www.instagram.com/p/DdwalmrkTSK/", dir)
      assert {:ok, %Post{} = photos} = Post.from_ytdlp(entries)
      assert items(photos) == [:photo, :photo, :photo]

      assert {:ok, entries} = Ytdlp.metadata("https://www.instagram.com/p/Ddwoj5kBk9X/", dir)
      assert {:ok, %Post{code: "Ddwoj5kBk9X"} = photo} = Post.from_ytdlp(entries)
      assert items(photo) == [:photo]
      assert_downloadable(photo)

      assert {:ok, entries} = Ytdlp.metadata("https://www.instagram.com/p/Chunk8-jurw/", dir)
      assert {:ok, %Post{} = reel} = Post.from_ytdlp(entries)
      assert items(reel) == [:video]

      assert {:error, %Error{kind: kind} = error} =
               Ytdlp.metadata("https://www.instagram.com/p/DdwalmrkTSX/", dir)

      IO.puts("\nyt-dlp on a missing post: #{inspect(error.kind)} #{error.message}")
      assert kind in [:unavailable, :unsupported]
      assert File.ls!(dir) == []
    end

    test "is where route/3 falls back to when Instagram refuses its own requests", %{
      tmp_dir: tmp_dir
    } do
      refuse = fn conn -> Plug.Conn.send_resp(conn, 500, "") end
      Application.put_env(:angler, Instagram, req_options: [plug: refuse], retry_delays: [0, 0])
      dir = Path.join(tmp_dir, "entry")
      File.mkdir_p!(dir)

      assert {:album, %Post{code: "DduKfFmDxsG"} = post} =
               Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)

      assert items(post) == [:photo, :video]

      assert {:ytdlp, "https://www.instagram.com/p/Chunk8-jurw/", %{title: "“Gingerton”" <> _}} =
               Instagram.route("https://www.instagram.com/reel/Chunk8-jurw/", dir)
    end
  end
end
