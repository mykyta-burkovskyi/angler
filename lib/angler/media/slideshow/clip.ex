defmodule Angler.Media.Slideshow.Clip do
  @moduledoc """
  The part of a song a post plays (its clip), for slideshows whose sound is a
  window of a longer song: Instagram photo posts with music give the whole song
  plus where their clip starts and how long it is.

  `window/2` decides what to cut (pure): the clip, at least 1 s and at most 120 s
  long, faded out over up to 1 s when it ends mid-song; or `:whole` when the clip
  is the whole song. A window outside the song (e.g. another edit of it) starts
  at 0 instead. `cut/3` cuts it into a FLAC file of its own with ffmpeg
  (`Angler.Media.Slideshow.Commands.clip_args/3`), which `Slideshow.Render` then
  loops like any other sound: an input seek would not survive `-stream_loop`.
  """
  alias Angler.Media.{Error, Probe}
  alias Angler.Media.Slideshow.{Commands, Tools}

  @tolerance 0.05
  @min_seconds 1.0
  @max_seconds 120.0
  @max_fade 1.0
  @timeout :timer.minutes(1)

  @typedoc "Where the clip starts in the song, and how long it is (nil: to the song's end)."
  @type window :: {start :: float(), duration :: float() | nil}

  @typedoc "The part of the song to cut (seconds), and the fade-out length at its end, or nil."
  @type cut :: %{start: float(), stop: float(), fade: float() | nil}

  @doc """
  What to cut from a song of `duration` seconds (nil when unknown) to play the
  clip `window`: `:whole` when the clip starts within 0.05 s of the song's start
  and runs to its end, else the cut.

  A start that is not a positive number means 0; a clip length under 1 s (or not a
  number) means the rest of the song. A start later than 1 s before the song's end
  lies outside this file and becomes 0. The clip is at most 120 s long; a clip
  that ends within 0.05 s of the song's end runs to the end without a fade, any
  other fades out over a quarter of its length, at most 1 s.
  """
  @spec window(float() | nil, window()) :: :whole | cut()
  def window(duration, {start, clip}) do
    duration = if is_number(duration), do: duration / 1
    start = if is_number(start) and start > 0, do: start / 1, else: 0.0
    clip = if is_number(clip) and clip >= @min_seconds, do: clip / 1

    start = if duration && start > duration - @min_seconds, do: 0.0, else: start
    stop = start + min(clip || @max_seconds, @max_seconds)
    ends_song? = duration != nil and stop >= duration - @tolerance
    stop = if ends_song?, do: duration, else: stop

    if start <= @tolerance and ends_song? do
      :whole
    else
      fade = if ends_song?, do: nil, else: min(@max_fade, (stop - start) / 4)
      %{start: start, stop: stop, fade: fade}
    end
  end

  @doc """
  Cuts `cut` out of the song at `input` into a FLAC file at `output` and returns
  its length in seconds, as ffprobe measures it.

  `{:failed, error}` when the song could not be cut (ffmpeg failed on it, or the
  result is not audio or shorter than 1 s); `{:error, error}` when ffmpeg or
  ffprobe took too long (`:timeout`), could not run or ffprobe failed otherwise
  (`:internal`). `output` may be left behind on failure.
  """
  @spec cut(Path.t(), cut(), Path.t()) ::
          {:ok, float()} | {:failed, Error.t()} | {:error, Error.t()}
  def cut(input, cut, output) do
    with :ok <- Tools.ffmpeg(Commands.clip_args(input, cut, output), timeout: @timeout) do
      measure(output)
    end
  end

  defp measure(output) do
    case Probe.run(output) do
      {:ok, %Probe{has_audio?: true, duration: seconds}}
      when is_number(seconds) and seconds >= @min_seconds ->
        {:ok, seconds}

      {:ok, %Probe{}} ->
        {:failed, Error.new(:internal, "the cut sound is shorter than 1 s")}

      {:error, %Error{kind: :unsupported} = error} ->
        {:failed, error}

      {:error, error} ->
        {:error, error}
    end
  end
end
