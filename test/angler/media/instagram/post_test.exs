defmodule Angler.Media.Instagram.PostTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures

  alias Angler.Media.Error
  alias Angler.Media.Instagram.Post

  defp media(code) do
    graphql(code)
    |> Jason.decode!()
    |> get_in(["data", "xig_polaris_media", "if_not_gated_logged_out"])
  end

  describe "from_media/1 with recorded answers" do
    test "a single photo" do
      assert {:ok, %Post{items: [photo]} = post} = Post.from_media(media("Ddwoj5kBk9X"))

      assert %Post{
               code: "Ddwoj5kBk9X",
               caption: "joining the bedazzle trend, thanks to @muse 💎",
               username: "instagram",
               full_name: "Instagram",
               webpage_url: "https://www.instagram.com/p/Ddwoj5kBk9X/"
             } = post

      assert %{type: :photo, width: 2000, height: 2500, duration: nil, urls: [original, smaller]} =
               photo

      # The original (no size in `stp`), then the 1080 px version.
      assert original =~ "stp=dst-jpg_e35_tt6&"
      assert smaller =~ "p1080x1080"
      assert Post.album?(post)
    end

    test "carousels in display order" do
      assert {:ok, %Post{items: photos}} = Post.from_media(media("DdwalmrkTSK"))
      assert [%{type: :photo, width: 1080, height: 1440, urls: [_, _]} | _] = photos
      assert length(photos) == 3

      assert [first | _] = photos
      assert hd(first.urls) =~ "22636_18797172301001321_1840526250724222048_n.jpg"

      assert {:ok, %Post{items: [photo, video]} = post} = Post.from_media(media("DduKfFmDxsG"))
      assert %{type: :photo, width: 1080, height: 1350} = photo
      assert %{type: :video, width: 1080, height: 1350, duration: 17.875, urls: [url]} = video
      assert url =~ ".mp4?"
      assert post.caption =~ "Ready to post your next photo dump?"
      assert post.caption =~ "\n\nJust connect"
      assert Post.album?(post)

      assert {:ok, %Post{items: videos}} = Post.from_media(media("Ddr-AMmDxqn"))

      assert Enum.map(videos, &{&1.type, &1.duration}) ==
               [video: 7.666667, video: 19.133333, video: 13.366667]

      assert {:ok, %Post{items: twelve}} = Post.from_media(media("DdulMV-D4cS"))
      assert length(twelve) == 12
      assert Enum.all?(twelve, &match?(%{type: :photo, urls: [_, _]}, &1))
    end

    test "a reel is a single video, not an album" do
      assert {:ok, %Post{items: [video]} = post} = Post.from_media(media("Chunk8-jurw"))
      assert %{type: :video, width: 720, height: 1280, duration: 4.967, urls: [_url]} = video
      assert post.caption =~ "Gingerton"
      refute Post.album?(post)
    end
  end

  describe "from_media/1" do
    test "keeps at most 20 items and drops items without URLs" do
      items = for n <- 1..22, do: photo(name: "p#{n}")

      broken = %{
        "media_type" => 1,
        "image_versions2" => %{"candidates" => [%{"url" => "data:x"}]}
      }

      unknown = Map.put(photo(), "media_type", 8)

      assert {:ok, %Post{items: kept}} = Post.from_media(post([broken, unknown | items]))
      assert length(kept) == 20
      assert hd(hd(kept).urls) =~ "/p1.jpg"
    end

    test "orders candidates and videos by size when they carry dimensions" do
      photo =
        Map.put(photo(), "image_versions2", %{
          "candidates" => [
            %{"url" => "https://cdn.test/small.jpg", "width" => 320, "height" => 400},
            %{"url" => "https://cdn.test/large.jpg", "width" => 1080, "height" => 1350},
            %{"url" => "https://cdn.test/medium.jpg", "width" => 640, "height" => 800}
          ]
        })

      video =
        Map.put(video(), "video_versions", [
          %{"url" => "https://cdn.test/480.mp4", "width" => 480, "height" => 854},
          %{"url" => "https://cdn.test/720.mp4", "width" => 720, "height" => 1280},
          %{"url" => "https://cdn.test/720.mp4", "width" => 720, "height" => 1280}
        ])

      assert {:ok, %Post{items: [photo, video]}} = Post.from_media(post([photo, video]))
      assert photo.urls == ["https://cdn.test/large.jpg", "https://cdn.test/medium.jpg"]
      assert video.urls == ["https://cdn.test/720.mp4", "https://cdn.test/480.mp4"]
    end

    test "starts with the smaller version of a photo too large for Telegram" do
      for {width, height} <- [{6000, 4500}, {200, 4100}] do
        assert {:ok, %Post{items: [%{urls: [url]}]}} =
                 Post.from_media(post([photo(width: width, height: height)]))

        assert url =~ "_1080.jpg"
      end

      assert {:ok, %Post{items: [%{urls: [_original, _smaller]}]}} =
               Post.from_media(post([photo(width: 5000, height: 5000)]))
    end

    test "reads durations from video_duration or the DASH manifest" do
      with_duration =
        video() |> Map.put("video_duration", 12) |> Map.delete("video_dash_manifest")

      hours = video(duration: "1H2M3.5")
      no_duration = Map.delete(video(), "video_dash_manifest")

      assert {:ok, %Post{items: items}} =
               Post.from_media(post([with_duration, hours, no_duration]))

      assert Enum.map(items, & &1.duration) == [12.0, 3723.5, nil]
    end

    test "reads blank or missing captions and users as nil" do
      assert {:ok, %Post{caption: nil, username: nil, full_name: nil} = post} =
               photo()
               |> Map.merge(%{"caption" => %{"text" => " \n "}, "code" => "Cx"})
               |> Post.from_media()

      assert Post.title(post) == "Instagram post"
    end

    test "fails posts without photos or videos" do
      error = Error.new(:unsupported, "This Instagram post has no photos or videos")
      assert Post.from_media(%{"media_type" => 8, "carousel_media" => []}) == {:error, error}
      assert Post.from_media(%{"media_type" => 2, "video_versions" => []}) == {:error, error}
    end
  end

  describe "from_ytdlp/1" do
    test "a carousel of a photo and a video" do
      entries = ytdlp_entries("DduKfFmDxsG")

      assert {:ok, %Post{items: [photo, video]} = post} = Post.from_ytdlp(Enum.reverse(entries))

      assert %Post{
               code: "DduKfFmDxsG",
               username: "instagram",
               full_name: "Instagram",
               webpage_url: "https://www.instagram.com/p/DduKfFmDxsG/"
             } = post

      assert post.caption =~ "Ready to post your next photo dump?"

      # The best thumbnail (the original), then the next largest.
      assert %{type: :photo, urls: [original, next]} = photo
      assert original =~ "stp=dst-jpg_e35_tt6&"
      assert next =~ "p720x720"

      # Only the progressive MP4 (one URL listed three times), not the DASH streams.
      assert %{type: :video, urls: [url], duration: nil} = video
      assert url =~ ".mp4?"
      refute url =~ "dash"
    end

    test "photos of a carousel and a single photo" do
      assert {:ok, %Post{code: "DdwalmrkTSK", items: photos}} =
               Post.from_ytdlp(ytdlp_entries("DdwalmrkTSK"))

      assert Enum.map(photos, & &1.type) == [:photo, :photo, :photo]

      assert {:ok, %Post{code: "Ddwoj5kBk9X", items: [%{type: :photo, urls: [_, _]}]} = post} =
               Post.from_ytdlp(ytdlp_entries("Ddwoj5kBk9X"))

      assert Post.album?(post)
    end

    test "falls back to formats with audio and video, and sorts thumbnails by preference" do
      entry = %{
        "id" => "Cvideo",
        "duration" => 9,
        "width" => 720,
        "height" => 1280,
        "formats" => [
          %{
            "format_id" => "dash-v",
            "url" => "https://cdn.test/v.mp4",
            "vcodec" => "avc1",
            "acodec" => "none"
          },
          %{
            "format_id" => "dash-a",
            "url" => "https://cdn.test/a.m4a",
            "vcodec" => "none",
            "acodec" => "mp4a"
          },
          %{
            "format_id" => "dash-av",
            "url" => "https://cdn.test/av.mp4",
            "vcodec" => "avc1",
            "acodec" => "mp4a"
          }
        ]
      }

      photo = %{
        "id" => "Cphoto",
        "playlist_index" => 1,
        "formats" => [],
        "thumbnails" => [
          %{"url" => "https://cdn.test/best.jpg", "preference" => 1},
          %{"url" => "https://cdn.test/small.jpg", "width" => 150, "height" => 150},
          %{"url" => "https://cdn.test/large.jpg", "width" => 1080, "height" => 1080}
        ]
      }

      assert {:ok, %Post{items: [photo, video]}} =
               Post.from_ytdlp([Map.put(entry, "playlist_index", 2), photo])

      assert photo.urls == ["https://cdn.test/best.jpg", "https://cdn.test/large.jpg"]

      assert video == %{
               type: :video,
               urls: ["https://cdn.test/av.mp4"],
               width: 720,
               height: 1280,
               duration: 9.0
             }
    end

    test "fails without items" do
      assert {:error, %Error{kind: :unsupported}} = Post.from_ytdlp([])

      assert {:error, %Error{kind: :unsupported}} =
               Post.from_ytdlp([%{"id" => "x", "formats" => [], "thumbnails" => []}])
    end
  end

  test "album?/1, photos?/1 and title/1" do
    photo = %{
      type: :photo,
      urls: ["https://cdn.test/p.jpg"],
      width: nil,
      height: nil,
      duration: nil
    }

    video = %{photo | type: :video}

    assert Post.album?(%Post{items: [photo]})
    assert Post.album?(%Post{items: [video, video]})
    refute Post.album?(%Post{items: [video]})

    assert Post.photos?(%Post{items: [photo]})
    assert Post.photos?(%Post{items: [photo, photo, photo]})
    refute Post.photos?(%Post{items: [photo, video]})
    refute Post.photos?(%Post{items: [video]})
    refute Post.photos?(%Post{items: []})

    assert Post.title(%Post{caption: "Text", username: "someone"}) == "Text"
    assert Post.title(%Post{username: "someone"}) == "Post by @someone"
    assert Post.title(%Post{}) == "Instagram post"
  end
end
