defmodule Angler.Media.PlanTest do
  use ExUnit.Case, async: true

  alias Angler.Media.{Plan, Probe}

  @mb 1_000_000

  # A 60 s 1080p H.264/AAC fast-start MP4 of 10 MB.
  defp probe(attrs \\ []) do
    struct!(
      %Probe{
        path: "/tmp/source.mp4",
        format_name: "mov,mp4,m4a,3gp,3g2,mj2",
        duration: 60.0,
        size: 10 * @mb,
        video_codec: "h264",
        video_profile: "High",
        pix_fmt: "yuv420p",
        width: 1920,
        height: 1080,
        display_width: 1920,
        display_height: 1080,
        fps: 30.0,
        audio_codec: "aac",
        audio_channels: 2,
        has_video?: true,
        has_audio?: true,
        faststart?: true
      },
      attrs
    )
  end

  # Duration that yields `kbps` of total budget for `target` bytes.
  defp duration_for(kbps, target), do: (floor(target * 0.95) - 65_536) * 8 / (kbps * 1000)

  describe "decide/2" do
    for {name, attrs, expected} <- [
          {"compatible fast-start mp4", [], :as_is},
          {"full-range yuvj420p", [pix_fmt: "yuvj420p"], :as_is},
          {"mp3 audio", [audio_codec: "mp3"], :as_is},
          {"no audio", [has_audio?: false, audio_codec: nil], :as_is},
          {"exactly the target size", [size: 50 * @mb], :as_is},
          {"moov at the end", [faststart?: false], :remux},
          {"matroska", [format_name: "matroska,webm", faststart?: false], :remux},
          {"mpeg-ts", [format_name: "mpegts", faststart?: false], :remux},
          {"opus audio", [audio_codec: "opus"], :audio_reencode},
          {"vorbis audio in webm", [format_name: "matroska,webm", audio_codec: "vorbis"],
           :audio_reencode},
          {"ac3 audio", [audio_codec: "ac3"], :audio_reencode}
        ] do
      test "#{name} -> #{inspect(expected)}" do
        assert Plan.decide(probe(unquote(Macro.escape(attrs))), 50 * @mb) == unquote(expected)
      end
    end

    for {name, attrs} <- [
          {"hevc", [video_codec: "hevc"]},
          {"vp9", [video_codec: "vp9"]},
          {"av1", [video_codec: "av1"]},
          {"vp8", [video_codec: "vp8"]},
          {"10-bit", [pix_fmt: "yuv420p10le"]},
          {"High 10 profile", [video_profile: "High 10"]},
          {"4:2:2", [pix_fmt: "yuv422p", video_profile: "High 4:2:2"]},
          {"4:4:4", [pix_fmt: "yuv444p", video_profile: "High 4:4:4 Predictive"]},
          {"HDR", [hdr?: true]},
          {"larger than the target", [size: 50 * @mb + 1]},
          {"unknown size", [size: nil]},
          {"too large with opus audio", [size: 60 * @mb, audio_codec: "opus"]},
          {"hevc in matroska", [video_codec: "hevc", format_name: "matroska,webm"]}
        ] do
      test "#{name} -> transcode" do
        assert {:transcode, %{}} = Plan.decide(probe(unquote(Macro.escape(attrs))), 50 * @mb)
      end
    end

    test "returns transcode errors" do
      assert Plan.decide(probe(video_codec: "vp9", duration: 3_600.0), 50 * @mb) ==
               {:error, :too_long}

      assert Plan.decide(probe(video_codec: "vp9", duration: nil), 50 * @mb) ==
               {:error, :unknown_duration}
    end
  end

  describe "transcode/2" do
    test "spends the budget of a 50 MB upload on a one minute 1080p video" do
      # budget = 47_500_000 - 65_536 bytes = 6324.6 kbps over 60 s, minus 128k audio
      assert Plan.transcode(probe(), 50 * @mb) ==
               {:transcode,
                %{
                  video_kbps: 6196,
                  audio_kbps: 128,
                  audio_channels: nil,
                  short_side: 1080,
                  fps: nil,
                  preset: "medium"
                }}
    end

    test "uses 96k audio and 360p for a ten minute video" do
      assert {:transcode, params} = Plan.transcode(probe(duration: 600.0), 50 * @mb)
      assert %{video_kbps: 536, audio_kbps: 96, short_side: 360} = params
    end

    test "uses 64k mono audio when the budget is tight" do
      assert {:transcode, params} = Plan.transcode(probe(duration: 1_500.0), 50 * @mb)
      assert %{video_kbps: 188, audio_kbps: 64, audio_channels: 1, short_side: 240} = params
    end

    test "uses the veryfast preset for videos longer than 20 minutes" do
      assert {:transcode, %{preset: "medium"}} =
               Plan.transcode(probe(duration: 1_200.0), 50 * @mb)

      assert {:transcode, %{preset: "veryfast"}} =
               Plan.transcode(probe(duration: 1_201.0), 50 * @mb)
    end

    test "rejects videos that would get less than 150 kbps of video" do
      assert Plan.transcode(probe(duration: 1_800.0), 50 * @mb) == {:error, :too_long}
      assert Plan.transcode(probe(), 100_000) == {:error, :too_long}
    end

    test "spends everything on video when there is no audio" do
      duration = duration_for(1_000, 50 * @mb)
      probe = probe(duration: duration, has_audio?: false, audio_codec: nil)

      assert {:transcode, %{audio_kbps: 0, audio_channels: nil, video_kbps: kbps}} =
               Plan.transcode(probe, 50 * @mb)

      assert kbps in 999..1000
    end

    for {total_kbps, audio_kbps, channels} <- [
          {5_000, 128, nil},
          {1_001, 128, nil},
          {999, 96, nil},
          {401, 96, nil},
          {399, 64, 1},
          {250, 64, 1}
        ] do
      test "picks #{audio_kbps}k audio for a #{total_kbps} kbps budget" do
        duration = duration_for(unquote(total_kbps), 50 * @mb)

        assert {:transcode, %{audio_kbps: unquote(audio_kbps), audio_channels: unquote(channels)}} =
                 Plan.transcode(probe(duration: duration), 50 * @mb)
      end
    end

    test "downmixes surround sound to stereo" do
      assert {:transcode, %{audio_channels: 2}} =
               Plan.transcode(probe(audio_channels: 6), 50 * @mb)
    end

    for {video_kbps, short_side} <- [
          {4_001, 1080},
          {3_999, 720},
          {2_001, 720},
          {1_999, 540},
          {1_101, 540},
          {1_099, 480},
          {801, 480},
          {799, 360},
          {401, 360},
          {399, 240},
          {151, 240}
        ] do
      test "scales to #{short_side}p for #{video_kbps} kbps of video" do
        duration = duration_for(unquote(video_kbps), 50 * @mb)
        probe = probe(duration: duration, has_audio?: false, audio_codec: nil)

        assert {:transcode, %{short_side: unquote(short_side)}} = Plan.transcode(probe, 50 * @mb)
      end
    end

    test "never upscales and keeps the short side even" do
      small = probe(width: 640, height: 360, display_width: 640, display_height: 360)
      assert {:transcode, %{short_side: 360}} = Plan.transcode(small, 50 * @mb)

      odd = probe(width: 721, height: 405, display_width: 721, display_height: 405)
      assert {:transcode, %{short_side: 404}} = Plan.transcode(odd, 50 * @mb)
    end

    test "uses the short side of portrait videos" do
      portrait = probe(width: 1080, height: 1920, display_width: 1080, display_height: 1920)
      assert {:transcode, %{short_side: 1080}} = Plan.transcode(portrait, 50 * @mb)
    end

    test "caps the bit rate per resolution" do
      short = probe(duration: 5.0)

      assert {:transcode, %{video_kbps: 8_000, short_side: 1080}} =
               Plan.transcode(short, 50 * @mb)

      small = probe(duration: 5.0, width: 640, height: 360)
      assert {:transcode, %{video_kbps: 1_500, short_side: 360}} = Plan.transcode(small, 50 * @mb)

      odd = probe(duration: 5.0, width: 721, height: 405)
      assert {:transcode, %{video_kbps: 2_500, short_side: 404}} = Plan.transcode(odd, 50 * @mb)
    end

    test "caps high frame rates at 30 fps only when bits are scarce" do
      tight = probe(fps: 60.0, duration: duration_for(1_400, 50 * @mb))
      assert {:transcode, %{fps: 30}} = Plan.transcode(tight, 50 * @mb)

      plenty = probe(fps: 60.0, duration: duration_for(3_000, 50 * @mb))
      assert {:transcode, %{fps: nil}} = Plan.transcode(plenty, 50 * @mb)

      normal = probe(fps: 30.0, duration: duration_for(500, 50 * @mb))
      assert {:transcode, %{fps: nil}} = Plan.transcode(normal, 50 * @mb)
    end

    test "requires a known, positive duration" do
      assert Plan.transcode(probe(duration: nil), 50 * @mb) == {:error, :unknown_duration}
      assert Plan.transcode(probe(duration: 0.0), 50 * @mb) == {:error, :unknown_duration}
    end
  end

  describe "retry_params/2" do
    setup do
      %{
        params: %{
          video_kbps: 1_000,
          audio_kbps: 96,
          audio_channels: nil,
          short_side: 720,
          fps: nil,
          preset: "medium"
        }
      }
    end

    test "first lowers the bit rate by 15%", %{params: params} do
      assert Plan.retry_params(params, 1) == %{params | video_kbps: 850}
    end

    test "then also moves to the next lower resolution", %{params: params} do
      assert Plan.retry_params(%{params | video_kbps: 850}, 2) == %{
               params
               | video_kbps: 722,
                 short_side: 540
             }
    end

    test "steps down from source-limited sizes and stops at 240p", %{params: params} do
      assert %{short_side: 360} = Plan.retry_params(%{params | short_side: 404}, 2)
      assert %{short_side: 240} = Plan.retry_params(%{params | short_side: 240}, 2)
    end
  end
end
