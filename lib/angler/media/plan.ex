defmodule Angler.Media.Plan do
  @moduledoc """
  Decides how to turn a probed source into an MP4 that Telegram plays inline and that
  fits the upload limit, preferring the cheapest option:

    * `:as_is` - MP4/MOV with H.264 (8-bit 4:2:0) and AAC/MP3 (or no) audio that fits
      and is already fast start: sent unchanged
    * `:remux` - same codecs in another container (MKV/WebM/TS/...) or without fast
      start: stream copy into MP4
    * `:audio_reencode` - H.264 video with other audio (Opus, Vorbis, ...): copy the
      video, encode AAC
    * `{:transcode, params}` - anything else (HEVC/VP9/AV1/VP8, 10-bit, HDR, 4:2:2/4:4:4)
      or too large: two-pass H.264 sized to the target

  Transcode budget: `floor(target * 0.95) - 64 KiB` bytes spread over the duration,
  minus the audio bit rate (128/96 kbps, or 64 kbps mono when the budget is tight).
  The resolution follows the video bit rate (never upscaling), the frame rate is
  capped at 30 fps when bits are scarce, and the bit rate is capped per resolution
  so small or short videos are not encoded wastefully. Below 150 kbps of video the
  result would be unwatchable: `{:error, :too_long}`.

  Pure functions only; `Angler.Media.Ffmpeg` executes the plan.
  """
  alias Angler.Media.Probe

  # Short side => largest useful video bit rate (kbps) at that resolution.
  @quality_caps [
    {240, 800},
    {360, 1_500},
    {480, 2_500},
    {540, 3_000},
    {720, 5_000},
    {1080, 8_000}
  ]
  # Minimum video bit rate (kbps) for each short side, best first.
  @ladder [{1080, 4_000}, {720, 2_000}, {540, 1_100}, {480, 800}, {360, 400}, {240, 0}]
  @min_video_kbps 150
  @low_bitrate_fps_kbps 1_500
  @long_video_seconds 20 * 60
  @container_overhead 65_536

  @typedoc """
  Two-pass H.264 settings: bit rates in kbps (`audio_kbps` 0 = no audio track),
  `audio_channels` to downmix to (nil keeps the source layout), the target short
  side in pixels (even), an optional frame rate cap and the x264 preset.
  """
  @type params :: %{
          video_kbps: pos_integer(),
          audio_kbps: non_neg_integer(),
          audio_channels: 1 | 2 | nil,
          short_side: pos_integer(),
          fps: pos_integer() | nil,
          preset: String.t()
        }

  @type t :: :as_is | :remux | :audio_reencode | {:transcode, params()}

  @doc "Picks the cheapest way to make `probe` fit `target_bytes`, see the module doc."
  @spec decide(Probe.t(), pos_integer()) :: t() | {:error, :too_long | :unknown_duration}
  def decide(%Probe{} = probe, target_bytes) do
    cond do
      not (h264?(probe) and fits?(probe, target_bytes)) -> transcode(probe, target_bytes)
      not audio_compatible?(probe) -> :audio_reencode
      mp4?(probe) and probe.faststart? -> :as_is
      true -> :remux
    end
  end

  defp h264?(%Probe{} = probe) do
    probe.video_codec == "h264" and probe.pix_fmt in ["yuv420p", "yuvj420p"] and not probe.hdr? and
      not String.starts_with?(probe.video_profile || "", ["High 10", "High 4:2:2", "High 4:4:4"])
  end

  defp fits?(%Probe{size: size}, target_bytes), do: is_integer(size) and size <= target_bytes

  defp audio_compatible?(%Probe{has_audio?: false}), do: true
  defp audio_compatible?(%Probe{audio_codec: codec}), do: codec in ["aac", "mp3"]

  defp mp4?(%Probe{format_name: name}), do: is_binary(name) and String.contains?(name, "mp4")

  @doc """
  Two-pass H.264 settings that make `probe` fit `target_bytes`, or an error when the
  video is too long for the budget or its duration is unknown.
  """
  @spec transcode(Probe.t(), pos_integer()) ::
          {:transcode, params()} | {:error, :too_long | :unknown_duration}
  def transcode(%Probe{duration: duration} = probe, target_bytes)
      when is_number(duration) and duration > 0 do
    budget = floor(target_bytes * 0.95) - @container_overhead
    total_kbps = budget * 8 / duration / 1000
    {audio_kbps, audio_channels} = audio(probe, total_kbps)
    video_budget = total_kbps - audio_kbps

    if video_budget < @min_video_kbps do
      {:error, :too_long}
    else
      short_side = short_side(video_budget, probe)

      {:transcode,
       %{
         video_kbps: min(floor(video_budget), quality_cap(short_side)),
         audio_kbps: audio_kbps,
         audio_channels: audio_channels,
         short_side: short_side,
         fps: fps_cap(probe, video_budget),
         preset: if(duration > @long_video_seconds, do: "veryfast", else: "medium")
       }}
    end
  end

  def transcode(%Probe{}, _target_bytes), do: {:error, :unknown_duration}

  defp fps_cap(%Probe{fps: fps}, video_kbps)
       when is_number(fps) and fps > 30 and video_kbps < @low_bitrate_fps_kbps,
       do: 30

  defp fps_cap(%Probe{}, _video_kbps), do: nil

  defp audio(%Probe{has_audio?: false}, _total_kbps), do: {0, nil}
  defp audio(%Probe{} = probe, total_kbps) when total_kbps >= 1_000, do: {128, stereo(probe)}
  defp audio(%Probe{} = probe, total_kbps) when total_kbps >= 400, do: {96, stereo(probe)}
  defp audio(%Probe{}, _total_kbps), do: {64, 1}

  # Downmix surround sound; keep mono and stereo as they are.
  defp stereo(%Probe{audio_channels: channels}) when is_integer(channels) and channels > 2, do: 2
  defp stereo(%Probe{}), do: nil

  defp short_side(video_kbps, %Probe{} = probe) do
    {rung, _min_kbps} = Enum.find(@ladder, fn {_side, min_kbps} -> video_kbps >= min_kbps end)

    case source_short_side(probe) do
      nil -> rung
      source -> source |> min(rung) |> even()
    end
  end

  defp source_short_side(%Probe{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: min(width, height)

  defp source_short_side(%Probe{}), do: nil

  defp even(side), do: max(div(side, 2) * 2, 2)

  defp quality_cap(short_side) do
    Enum.find_value(@quality_caps, 8_000, fn {side, cap} -> if short_side <= side, do: cap end)
  end

  @doc """
  Settings for another attempt after an encode came out larger than the target:
  85% of the bit rate first, then additionally the next lower resolution.
  """
  @spec retry_params(params(), pos_integer()) :: params()
  def retry_params(params, 1), do: %{params | video_kbps: reduce(params.video_kbps)}

  def retry_params(params, _attempt) do
    %{params | video_kbps: reduce(params.video_kbps), short_side: lower_side(params.short_side)}
  end

  defp reduce(kbps), do: max(floor(kbps * 0.85), 1)

  defp lower_side(short_side) do
    Enum.find_value(@ladder, short_side, fn {side, _kbps} -> if side < short_side, do: side end)
  end
end
