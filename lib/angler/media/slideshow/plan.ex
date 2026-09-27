defmodule Angler.Media.Slideshow.Plan do
  @moduledoc """
  Pure decisions for turning N images and an optional sound into a video: the
  canvas size, how long each image shows, and the encoder's size budget.

  ## Canvas

  Every image's aspect ratio snaps to the nearest preset (smallest
  `|ln(image ratio / preset ratio)|`); the preset most images snap to wins, ties
  go to the earliest image (the cover). A fixed 9:16 canvas would be mostly blur
  for the landscape and 3:4 photos TikTok posts often have. The 720 presets are
  the fallback when the 1080 result does not fit the upload limit.

  ## Timeline (30 fps, at most 90 s)

  A shorter maximum video duration (a dashboard setting) lowers that limit, but
  never below 3 s.

    * no sound: 3 s per image (a single image shows for 3 s)
    * one image: the length of the sound (at least 3 s)
    * otherwise each image shows `d = clamp(A / N, 3, 6)` seconds for sound length
      `A`. When one pass through the images (`N * d`) lasts at least as long as the
      sound, the video is that pass (capped at the limit, e.g. 35 images show for
      2.57 s each in 90 s) and the sound loops if it is shorter; else the video
      lasts as long as the sound (capped) and cycles through the images in
      `ceil(D / 6)` equal slots

  Slot boundaries are whole frames (`round(30 * elapsed)`), so cuts never drift
  and the duration is a whole number of frames. The sound loops when the video is
  longer than it and fades out over `min(1.5, D / 3)` seconds when it does not end
  with the video.
  """

  @fps 30
  @min_slide 3.0
  @max_slide 6.0
  @silent_slide 3.0
  @max_duration 90.0
  @fade_out 1.5
  @tolerance 0.05

  @presets [
    hd: [
      {1080, 1920},
      {1080, 1620},
      {1080, 1440},
      {1080, 1350},
      {1080, 1080},
      {1350, 1080},
      {1440, 1080},
      {1620, 1080},
      {1920, 1080}
    ],
    sd: [
      {720, 1280},
      {720, 1080},
      {720, 960},
      {720, 900},
      {720, 720},
      {900, 720},
      {960, 720},
      {1080, 720},
      {1280, 720}
    ]
  ]

  # CRF and the VBV cap ceiling (kbit/s) per canvas size.
  @qualities [hd: %{crf: 20, max_kbps: 3000}, sd: %{crf: 22, max_kbps: 2000}]
  @min_kbps 500
  @audio_bps 128_000

  defstruct [:duration, slots: [], fps: @fps, audio_loop: false, audio_fade: nil]

  @typedoc """
  `slots` lists `{image_index, frames}` in playing order; `duration` (seconds) is
  their total frame count divided by `fps`; `audio_fade` is the fade-out length in
  seconds, or nil.
  """
  @type t :: %__MODULE__{
          duration: float(),
          slots: [{non_neg_integer(), pos_integer()}],
          fps: pos_integer(),
          audio_loop: boolean(),
          audio_fade: float() | nil
        }

  @type size :: :hd | :sd

  @doc "Frames per second of every slideshow."
  @spec fps() :: pos_integer()
  def fps, do: @fps

  @doc "Canvas presets for `size`, portrait to landscape."
  @spec presets(size()) :: [{pos_integer(), pos_integer()}]
  def presets(size), do: Keyword.fetch!(@presets, size)

  @doc "CRF and VBV ceiling (`%{crf: 20, max_kbps: 3000}`) for a canvas size."
  @spec quality(size()) :: %{crf: pos_integer(), max_kbps: pos_integer()}
  def quality(size), do: Keyword.fetch!(@qualities, size)

  @doc "The canvas `{width, height}` for images of the given dimensions, in order."
  @spec canvas([{pos_integer(), pos_integer()}], size()) :: {pos_integer(), pos_integer()}
  def canvas(dimensions, size \\ :hd)

  def canvas([], size), do: hd(presets(size))

  def canvas(dimensions, size) do
    snapped = Enum.map(dimensions, &nearest_preset(&1, size))
    votes = Enum.frequencies(snapped)
    most = votes |> Map.values() |> Enum.max()
    Enum.find(snapped, &(votes[&1] == most))
  end

  @doc "The preset whose aspect ratio is closest to that of `{width, height}`."
  @spec nearest_preset({pos_integer(), pos_integer()}, size()) :: {pos_integer(), pos_integer()}
  def nearest_preset({width, height}, size) do
    Enum.min_by(presets(size), fn {w, h} -> abs(:math.log(w / h / (width / height))) end)
  end

  @doc """
  The timeline for `count` images and a sound of `audio_duration` seconds (nil or
  under 0.1 s means no sound), at most `max_duration` seconds long (nil or above
  90 means 90; never under 3).
  """
  @spec timeline(pos_integer(), number() | nil, number() | nil) :: t()
  def timeline(count, audio_duration, max_duration \\ nil) when is_integer(count) and count > 0 do
    audio = if is_number(audio_duration) and audio_duration > 0.1, do: audio_duration / 1
    {seconds, slot_count} = layout(count, audio, limit(max_duration))
    slot_seconds = seconds / slot_count

    boundaries = for k <- 0..slot_count, do: round(k * slot_seconds * @fps)

    slots =
      boundaries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(fn [from, to], k -> {rem(k, count), to - from} end)

    duration = List.last(boundaries) / @fps
    plan = %__MODULE__{duration: duration, slots: slots}

    if audio do
      fade? = abs(duration - audio) > @tolerance

      %{
        plan
        | audio_loop: duration > audio + @tolerance,
          audio_fade: if(fade?, do: min(@fade_out, duration / 3))
      }
    else
      plan
    end
  end

  defp limit(max_duration) when is_number(max_duration),
    do: max_duration |> min(@max_duration) |> max(@min_slide) |> Kernel./(1)

  defp limit(nil), do: @max_duration

  # {video seconds, number of equal slots}
  defp layout(count, nil, limit), do: {min(max(count * @silent_slide, @min_slide), limit), count}
  defp layout(1, audio, limit), do: {max(min(audio, limit), @min_slide), 1}

  defp layout(count, audio, limit) do
    slide = audio |> Kernel./(count) |> max(@min_slide) |> min(@max_slide)

    if count * slide >= audio - 1.0e-6 do
      {min(count * slide, limit), count}
    else
      seconds = min(audio, limit)
      {seconds, ceil(seconds / @max_slide - 1.0e-9)}
    end
  end

  @doc """
  x264 VBV cap (`-maxrate`, kbit/s) so video plus 128 kbit/s audio stay within 90%
  of `target_bytes` over `duration` seconds, between 500 and the `ceiling` of the
  canvas size's quality. For a 50 MB target and up to 90 s this is the ceiling.
  """
  @spec maxrate_kbps(number(), pos_integer(), boolean(), pos_integer()) :: pos_integer()
  def maxrate_kbps(duration, target_bytes, audio?, ceiling) do
    audio_bps = if audio?, do: @audio_bps, else: 0
    budget = 0.9 * (target_bytes * 8 / max(duration, 1.0) - audio_bps) / 1000
    budget |> floor() |> min(ceiling) |> max(@min_kbps)
  end
end
