defmodule Angler.MediaTest do
  use ExUnit.Case, async: true

  alias Angler.Media
  alias Angler.Media.{Download, Error, Output, Probe}

  describe "parse_version/2" do
    test "extracts tool versions from their first output line" do
      assert Media.parse_version("yt-dlp", "2026.08.19\n") == "2026.08.19"

      assert Media.parse_version(
               "ffmpeg",
               "ffmpeg version 9.0.2-https://www.martin-riedl.de Copyright (c) 2000-2026 the FFmpeg developers"
             ) == "9.0.2"

      assert Media.parse_version(
               "ffmpeg",
               "ffmpeg version 7.1.5-0+deb13u1 Copyright (c) 2000-2025"
             ) ==
               "7.1.5"

      assert Media.parse_version("ffmpeg", "ffmpeg version n9.0.2 Copyright") == "9.0.2"

      assert Media.parse_version("ffmpeg", "ffmpeg version N-120000-gabcdef Copyright") ==
               "N-120000-gabcdef"

      assert Media.parse_version("ffmpeg", "something else") == nil

      assert Media.parse_version(
               "deno",
               "deno 2.9.7 (stable, release, aarch64-unknown-linux-gnu)"
             ) ==
               "2.9.7"

      assert Media.parse_version("deno", "") == nil
      assert Media.parse_version("yt-dlp", "  ") == nil
    end
  end

  test "format_mb/1 uses decimal megabytes" do
    assert Media.format_mb(50_000_000) == "50 MB"
    assert Media.format_mb(2_000_000_000) == "2000 MB"
    assert Media.format_mb(47_500_000) == "47.5 MB"
    assert Media.format_mb(102_400) == "0.1 MB"
  end

  test "with_article/1 puts the indefinite article before a noun" do
    assert Media.with_article("Instagram post") == "an Instagram post"
    assert Media.with_article("Threads post") == "a Threads post"
    assert Media.with_article("") == "a "
  end

  test "format_duration/1 formats time limits" do
    assert Media.format_duration(:timer.minutes(30)) == "30 minutes"
    assert Media.format_duration(:timer.minutes(1)) == "1 minute"
    assert Media.format_duration(:timer.seconds(45)) == "45 seconds"
    assert Media.format_duration(1_000) == "1 second"
    assert Media.format_duration(90_000) == "90 seconds"
    assert Media.format_duration(500) == "0 seconds"
  end

  describe "throttle/2" do
    test "calls through at most once per interval" do
      test = self()
      throttled = Media.throttle(&send(test, {:called, &1}), 60_000)

      throttled.(1)
      throttled.(2)

      assert_received {:called, 1}
      refute_received {:called, 2}
    end

    test "calls through again once the interval passed" do
      test = self()
      throttled = Media.throttle(&send(test, {:called, &1}), 0)

      throttled.(1)
      throttled.(2)

      assert_received {:called, 1}
      assert_received {:called, 2}
    end

    test "keeps separate state per throttled function" do
      test = self()
      first = Media.throttle(&send(test, {:first, &1}), 60_000)
      second = Media.throttle(&send(test, {:second, &1}), 60_000)

      first.(1)
      second.(1)

      assert_received {:first, 1}
      assert_received {:second, 1}
    end
  end

  describe "download/3 of Instagram posts" do
    @describetag :tmp_dir
    @describetag :capture_log

    @cdn "https://scontent-iev1-1.cdninstagram.com"

    # Instagram's logged-out GraphQL answer for the post, and its CDN.
    defp stub_instagram(media) do
      Req.Test.stub(Angler.Media.Instagram, fn conn ->
        case {conn.method, conn.host, conn.request_path} do
          {"POST", "www.instagram.com", "/api/graphql"} ->
            answer = %{"data" => %{"xig_polaris_media" => %{"if_not_gated_logged_out" => media}}}

            conn
            |> Plug.Conn.put_resp_content_type("text/javascript")
            |> Plug.Conn.send_resp(200, Jason.encode!(answer))

          {"GET", "scontent-iev1-1.cdninstagram.com", path} ->
            Plug.Conn.send_resp(conn, 200, Path.basename(path))
        end
      end)
    end

    test "downloads a post with photos as an album", %{tmp_dir: dir} do
      stub_instagram(%{
        "code" => "DduKfFmDxsG",
        "media_type" => 8,
        "caption" => %{"text" => "Hello from the post"},
        "user" => %{"username" => "instagram"},
        "carousel_media" => [
          %{
            "media_type" => 1,
            "image_versions2" => %{"candidates" => [%{"url" => "#{@cdn}/v/t51/1.jpg?oh=a"}]}
          },
          %{
            "media_type" => 2,
            "video_versions" => [%{"type" => 101, "url" => "#{@cdn}/o1/v/t16/2.mp4?oh=b"}]
          }
        ]
      })

      assert {:ok, %Download{kind: :album, items: [photo, video]} = download} =
               Media.download("https://www.instagram.com/p/DduKfFmDxsG/", dir,
                 max_source_bytes: 1_000_000,
                 max_duration: 600
               )

      assert %Download{
               title: "Hello from the post",
               extractor: "Instagram",
               webpage_url: "https://www.instagram.com/p/DduKfFmDxsG/",
               max_duration: 600,
               size: 10
             } = download

      assert {photo.type, File.read!(photo.path)} == {:photo, "1.jpg"}
      assert {video.type, File.read!(video.path)} == {:video, "2.mp4"}
    end
  end

  describe "download/3 of Threads posts" do
    @describetag :tmp_dir
    @describetag :capture_log

    # The post page on Threads, and the files on Instagram's CDN.
    defp stub_threads(media) do
      Angler.ThreadsFixtures.stub_pages(%{media["code"] => media})

      Req.Test.stub(Angler.Media.Instagram, fn conn ->
        Plug.Conn.send_resp(conn, 200, Path.basename(conn.request_path))
      end)
    end

    test "downloads a single video from the CDN", %{tmp_dir: dir} do
      stub_threads(Angler.ThreadsFixtures.media("DeMqtuYgkaL"))

      assert {:ok, %Download{kind: :video} = download} =
               Media.download("https://www.threads.com/@nasa/post/DeMqtuYgkaL", dir,
                 max_source_bytes: 1_000_000
               )

      assert %Download{
               extractor: "Threads",
               webpage_url: "https://www.threads.com/@nasa/post/DeMqtuYgkaL",
               duration: 89.365334
             } = download

      assert download.title =~ "Artemis II"
      assert download.path == Path.join(dir, "source.mp4")
      assert File.read!(download.path) =~ ".mp4"
    end

    test "downloads a carousel as an album", %{tmp_dir: dir} do
      stub_threads(Angler.ThreadsFixtures.media("Ddt7cL5EfUG"))

      assert {:ok, %Download{kind: :album, items: items} = download} =
               Media.download("https://www.threads.com/@zuck/post/Ddt7cL5EfUG", dir,
                 max_source_bytes: 1_000_000,
                 max_duration: 600
               )

      assert length(items) == 9
      assert %Download{extractor: "Threads", max_duration: 600} = download
      assert download.webpage_url == "https://www.threads.com/@zuck/post/Ddt7cL5EfUG"
    end

    test "fails text posts as unsupported", %{tmp_dir: dir} do
      stub_threads(Angler.ThreadsFixtures.media("Dd1MqfcG0aH"))

      assert Media.download("https://www.threads.com/@zuck/post/Dd1MqfcG0aH", dir, []) ==
               {:error, Error.new(:unsupported, "This Threads post has no photos or videos")}
    end
  end

  # Without a readable photo for ffmpeg there is no cover: that is logged.
  @tag :tmp_dir
  @tag :capture_log
  test "prepare/3 prepares albums item by item", %{tmp_dir: dir} do
    item_dir = Path.join([dir, "album", "01"])
    File.mkdir_p!(item_dir)
    source = Path.join(item_dir, "source.jpg")
    png = <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 640::32, 480::32, 8, 2, 0, 0, 0, 0::32>>
    File.write!(source, png)

    download = %Download{
      kind: :album,
      path: Path.join(dir, "album"),
      size: byte_size(png),
      items: [
        %{
          type: :photo,
          path: source,
          size: byte_size(png),
          width: nil,
          height: nil,
          duration: nil
        }
      ]
    }

    assert {:ok, %Output{kind: :album, width: 640, height: 480, items: [photo]}} =
             Media.prepare(download, dir, target_bytes: 50_000_000)

    assert photo.path == Path.join(item_dir, "photo.png")
    assert File.read!(photo.path) == png
  end

  describe "prepare/3" do
    @describetag :external
    @describetag :tmp_dir

    @mb 1_000_000

    # Generates a test video with ffmpeg's lavfi sources.
    defp source!(dir, name, args) do
      path = Path.join(dir, name)

      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [path],
          stderr_to_stdout: true
        )

      assert status == 0, output
      path
    end

    defp lavfi(size, seconds, opts \\ []) do
      rate = Keyword.get(opts, :rate, 30)
      video = ["-f", "lavfi", "-i", "testsrc2=size=#{size}:rate=#{rate}"]

      audio =
        if Keyword.get(opts, :audio, true),
          do: ["-f", "lavfi", "-i", "sine=frequency=440"],
          else: []

      video ++ audio ++ ["-t", to_string(seconds)]
    end

    defp h264, do: ~w(-c:v libx264 -preset ultrafast -pix_fmt yuv420p)

    defp prepare(source, dir, target) do
      test = self()
      download = %Download{path: source, size: File.stat!(source).size}

      Media.prepare(download, dir,
        target_bytes: target,
        on_progress: &send(test, {:progress, &1})
      )
    end

    defp assert_thumbnail(%Output{thumbnail_path: path}) do
      assert {:ok, %Probe{width: width, height: height}} = Probe.run(path)
      assert width <= 320 and height <= 320
      assert File.stat!(path).size < 200_000
    end

    defp assert_only_outputs(dir) do
      assert dir |> File.ls!() |> Enum.sort() == ["thumbnail.jpg", "video.mp4"]
    end

    defp progress_messages do
      receive do
        {:progress, progress} -> [progress | progress_messages()]
      after
        0 -> []
      end
    end

    test "moves a compatible fast-start MP4 into place", %{tmp_dir: dir} do
      source =
        source!(
          dir,
          "source.mp4",
          lavfi("640x360", 2) ++ h264() ++ ~w(-c:a aac -movflags +faststart)
        )

      size = File.stat!(source).size

      assert {:ok, output} = prepare(source, dir, 50 * @mb)

      assert %Output{
               path: path,
               size: ^size,
               duration: 2,
               width: 640,
               height: 360,
               video_codec: "h264",
               transcoded: false
             } = output

      assert path == Path.join(dir, "video.mp4")
      assert_thumbnail(output)
      assert_only_outputs(dir)
    end

    test "reports display dimensions of rotated videos sent as is", %{tmp_dir: dir} do
      landscape = source!(dir, "landscape.mp4", lavfi("640x360", 2) ++ h264() ++ ~w(-c:a aac))

      rotated =
        source!(
          dir,
          "source.mp4",
          ["-display_rotation", "90", "-i", landscape] ++ ~w(-c copy -movflags +faststart)
        )

      File.rm!(landscape)

      assert {:ok, %Output{width: 360, height: 640, transcoded: false}} =
               prepare(rotated, dir, 50 * @mb)
    end

    test "remuxes an MP4 whose index is at the end", %{tmp_dir: dir} do
      source = source!(dir, "source.mp4", lavfi("640x360", 2) ++ h264() ++ ~w(-c:a aac))
      refute Probe.faststart?(source)

      assert {:ok, %Output{transcoded: false, video_codec: "h264"} = output} =
               prepare(source, dir, 50 * @mb)

      assert Probe.faststart?(output.path)
      assert %{percent: nil, detail: "Remuxing"} in progress_messages()
      assert_only_outputs(dir)
    end

    test "remuxes H.264/AAC from Matroska", %{tmp_dir: dir} do
      source = source!(dir, "source.mkv", lavfi("640x360", 2) ++ h264() ++ ~w(-c:a aac))

      assert {:ok, %Output{transcoded: false, width: 640, height: 360} = output} =
               prepare(source, dir, 50 * @mb)

      assert {:ok, %Probe{format_name: "mov,mp4,m4a,3gp,3g2,mj2", faststart?: true}} =
               Probe.run(output.path)

      assert_only_outputs(dir)
    end

    test "re-encodes Opus audio to AAC and keeps the video", %{tmp_dir: dir} do
      source = source!(dir, "source.mkv", lavfi("640x360", 2) ++ h264() ++ ~w(-c:a libopus))

      assert {:ok, %Output{transcoded: false} = output} = prepare(source, dir, 50 * @mb)

      assert {:ok, %Probe{video_codec: "h264", audio_codec: "aac", faststart?: true}} =
               Probe.run(output.path)

      assert %{percent: nil, detail: "Converting audio"} in progress_messages()
    end

    test "transcodes VP9/Opus WebM to H.264/AAC", %{tmp_dir: dir} do
      source =
        source!(
          dir,
          "source.webm",
          lavfi("640x360", 2) ++
            ~w(-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k -c:a libopus)
        )

      assert {:ok,
              %Output{transcoded: true, video_codec: "h264", width: 640, height: 360} = output} =
               prepare(source, dir, 50 * @mb)

      assert {:ok, %Probe{audio_codec: "aac", pix_fmt: "yuv420p", faststart?: true}} =
               Probe.run(output.path)

      assert_thumbnail(output)
      assert_only_outputs(dir)

      progress = progress_messages()
      assert Enum.any?(progress, &(&1.detail == "Encoding 360p · pass 1/2"))
      assert Enum.all?(progress, &(&1.percent >= 0 and &1.percent <= 100))
    end

    test "uses the duration yt-dlp reported when the container has none", %{tmp_dir: dir} do
      # A live WebM has no duration in the container or its streams.
      source =
        source!(
          dir,
          "source.webm",
          lavfi("640x360", 2) ++
            ~w(-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k -c:a libopus) ++
            ~w(-f webm -live 1)
        )

      assert {:ok, %Probe{duration: nil}} = Probe.run(source)

      download = %Download{path: source, size: File.stat!(source).size, duration: 2.0}

      assert {:ok, %Output{transcoded: true, video_codec: "h264", duration: 2}} =
               Media.prepare(download, dir, target_bytes: 50 * @mb)
    end

    test "transcodes a video that is too large to fit the target", %{tmp_dir: dir} do
      source =
        source!(
          dir,
          "source.mp4",
          lavfi("1280x720", 8) ++ ~w(-c:v libx264 -preset ultrafast -qp 5 -c:a aac)
        )

      assert File.stat!(source).size > 400_000

      assert {:ok, %Output{transcoded: true, size: size, width: width, height: height} = output} =
               prepare(source, dir, 400_000)

      assert size <= 400_000
      assert size == File.stat!(output.path).size
      assert rem(width, 2) == 0 and rem(height, 2) == 0
      assert height < 720
      assert output.duration == 8
      assert Probe.faststart?(output.path)
      assert_thumbnail(output)
      assert_only_outputs(dir)
    end

    test "auto-rotates portrait videos when transcoding", %{tmp_dir: dir} do
      landscape = source!(dir, "landscape.mp4", lavfi("1280x720", 4) ++ h264() ++ ~w(-c:a aac))

      rotated =
        source!(dir, "source.mp4", ["-display_rotation", "90", "-i", landscape, "-c", "copy"])

      File.rm!(landscape)

      assert {:ok, %Output{transcoded: true, width: 240, height: height} = output} =
               prepare(rotated, dir, 300_000)

      assert rem(height, 2) == 0 and height > 400
      assert {:ok, %Probe{rotation: 0, width: 240}} = Probe.run(output.path)
    end

    test "produces even dimensions from odd-sized 4:4:4 video without audio", %{tmp_dir: dir} do
      source =
        source!(
          dir,
          "source.mp4",
          lavfi("721x405", 2, audio: false) ++ ~w(-c:v libx264 -preset ultrafast -pix_fmt yuv444p)
        )

      assert {:ok, %Output{transcoded: true, width: width, height: 404} = output} =
               prepare(source, dir, 50 * @mb)

      assert rem(width, 2) == 0
      assert {:ok, %Probe{has_audio?: false, pix_fmt: "yuv420p"}} = Probe.run(output.path)
    end

    test "rejects videos too long for the target", %{tmp_dir: dir} do
      source = source!(dir, "source.mp4", lavfi("640x360", 2) ++ h264() ++ ~w(-c:a aac))

      assert {:error, %Error{kind: :too_large, message: "Video is too long to fit into 0.1 MB"}} =
               prepare(source, dir, 60_000)
    end

    test "rejects downloads without a video stream", %{tmp_dir: dir} do
      source = source!(dir, "source.m4a", ~w(-f lavfi -i sine -t 1 -c:a aac))

      assert {:error, %Error{kind: :unsupported, message: "This post has no video"}} =
               prepare(source, dir, 50 * @mb)
    end

    test "rejects files that are not media", %{tmp_dir: dir} do
      source = Path.join(dir, "source.mp4")
      File.write!(source, "<!DOCTYPE html><html><body>Too many requests</body></html>")

      assert {:error,
              %Error{kind: :unsupported, message: "Downloaded file is not a playable video"}} =
               prepare(source, dir, 50 * @mb)
    end
  end

  # Downloads from YouTube with the real yt-dlp; excluded by default. Run with:
  #   mix test test/angler/media_test.exs --include network
  @tag :external
  @tag :network
  @tag :tmp_dir
  @tag timeout: :timer.minutes(5)
  test "downloads and prepares a real video", %{tmp_dir: dir} do
    test = self()

    assert {:ok, %Download{} = download} =
             Media.download("https://www.youtube.com/watch?v=jNQXAC9IVRw", dir,
               target_bytes: 50_000_000,
               max_source_bytes: 100_000_000,
               max_duration: 600,
               on_progress: &send(test, {:progress, &1})
             )

    assert %Download{title: "Me at the zoo", extractor: "Youtube", video_codec: "avc1." <> _} =
             download

    assert_in_delta download.duration, 19, 1
    assert download.size == File.stat!(download.path).size
    assert_received {:progress, %{detail: _}}

    assert {:ok, %Output{video_codec: "h264", size: size, duration: duration} = output} =
             Media.prepare(download, dir, target_bytes: 50_000_000)

    assert size <= 50_000_000
    assert duration in 18..20
    assert Probe.faststart?(output.path)
    assert dir |> File.ls!() |> Enum.sort() == ["thumbnail.jpg", "video.mp4"]
  end
end
