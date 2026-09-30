defmodule Angler.Media.Probe do
  @moduledoc """
  Reads the properties of a media file with ffprobe.

  Only the first video stream that is not cover art (`attached_pic`) and the first
  audio stream are considered. ffprobe reports numbers as strings and often leaves
  stream durations and bit rates out (Matroska/WebM), so the container duration is
  used, falling back to the stream durations.

  Whether an MP4/MOV file is "fast start" (its `moov` index box comes before the
  `mdat` media data, so players can start before the whole file arrived) is
  determined by reading the top-level box headers, see `faststart?/1`.

  Configuration (`config :angler, Angler.Media.Probe`): `:timeout`, milliseconds
  before ffprobe is stopped (default 2 minutes; tests shorten it).
  """
  alias Angler.Media
  alias Angler.Media.{Command, Error}
  alias Angler.Media.Probe.Mp4

  @entries "format=format_name,duration,size,bit_rate" <>
             ":stream=index,codec_type,codec_name,profile,pix_fmt,width,height,avg_frame_rate," <>
             "bit_rate,duration,channels,color_transfer" <>
             ":stream_disposition=attached_pic:stream_side_data=side_data_type,rotation"
  @timeout :timer.minutes(2)
  @hdr_transfers ["smpte2084", "arib-std-b67"]
  @invalid_input ["Invalid data found", "moov atom not found", "EBML header parsing failed"]

  defstruct [
    :path,
    :format_name,
    :duration,
    :size,
    :bit_rate,
    :video_codec,
    :video_profile,
    :pix_fmt,
    :width,
    :height,
    :display_width,
    :display_height,
    :fps,
    :video_bit_rate,
    :audio_codec,
    :audio_channels,
    :audio_bit_rate,
    rotation: 0,
    hdr?: false,
    has_video?: false,
    has_audio?: false,
    faststart?: false
  ]

  @typedoc """
  Probe result. `width`/`height` are the coded dimensions; `display_width` and
  `display_height` have the rotation applied. `duration` is in seconds, `fps` is the
  average frame rate, bit rates are in bits per second.
  """
  @type t :: %__MODULE__{
          path: Path.t() | nil,
          format_name: String.t() | nil,
          duration: float() | nil,
          size: non_neg_integer() | nil,
          bit_rate: non_neg_integer() | nil,
          video_codec: String.t() | nil,
          video_profile: String.t() | nil,
          pix_fmt: String.t() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          display_width: pos_integer() | nil,
          display_height: pos_integer() | nil,
          fps: float() | nil,
          video_bit_rate: non_neg_integer() | nil,
          audio_codec: String.t() | nil,
          audio_channels: pos_integer() | nil,
          audio_bit_rate: non_neg_integer() | nil,
          rotation: integer(),
          hdr?: boolean(),
          has_video?: boolean(),
          has_audio?: boolean(),
          faststart?: boolean()
        }

  @doc """
  Probes the file at `path`.

  Files ffprobe cannot read as media return an error of kind `:unsupported`; an
  ffprobe that runs longer than the timeout (2 minutes, see the module
  documentation) returns kind `:timeout`, as the other tools do; a missing
  ffprobe or other failures return kind `:internal`.
  """
  @spec run(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def run(path) do
    args = [
      "-v",
      "error",
      "-hide_banner",
      "-print_format",
      "json",
      "-show_entries",
      @entries,
      path
    ]

    ffprobe = Media.config(:ffprobe_path, "ffprobe")
    timeout = :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(:timeout, @timeout)

    case Command.run(ffprobe, args, timeout: timeout, max_lines: 10_000) do
      {:ok, %{exit_status: 0, output: lines}} ->
        with {:ok, json} <- decode(lines), do: {:ok, finish(parse(json), path)}

      {:ok, %{exit_status: status, output: lines}} ->
        {:error, failure(status, lines)}

      {:error, :timeout, _lines} ->
        {:error,
         Error.new(:timeout, "ffprobe took longer than #{Media.format_duration(timeout)}")}

      {:error, :enoent} ->
        {:error, Error.new(:internal, "ffprobe not found")}

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not start ffprobe: #{inspect(reason)}")}

      {:error, reason, lines} ->
        {:error,
         Error.new(:internal, "ffprobe failed: #{inspect(reason)}", Enum.join(lines, "\n"))}
    end
  end

  @doc false
  # Decodes ffprobe's JSON document from its output `lines`. Its messages (errors,
  # warnings) share the output: before the document or, since ffprobe 9, after its
  # opening "{" (see `json_line?/1`). Public for tests.
  @spec decode([String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def decode(lines) do
    json = lines |> Enum.filter(&json_line?/1) |> Enum.join("\n")

    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      _other ->
        {:error,
         Error.new(:internal, "Could not parse the ffprobe output", Enum.join(lines, "\n"))}
    end
  end

  @doc false
  # The error for ffprobe's exit `status` and output `lines`, from its messages
  # (every line not part of its JSON document, see decode/1): kind `:unsupported`
  # when they say the file is not media. Public for tests.
  @spec failure(integer(), [String.t()]) :: Error.t()
  def failure(status, lines) do
    messages = Enum.reject(lines, &json_line?/1)
    output = Enum.join(messages, "\n")

    cond do
      Enum.any?(messages, &String.contains?(&1, @invalid_input)) ->
        Error.new(:unsupported, "Not a playable media file", output)

      messages == [] ->
        Error.new(:internal, "ffprobe failed (exit #{status})", output)

      true ->
        Error.new(:internal, "ffprobe failed (exit #{status}): #{List.last(messages)}", output)
    end
  end

  # A line of ffprobe's JSON document: its outer braces on lines of their own,
  # blank lines, and indented members ("key": value) and the braces and brackets
  # of nested values. Messages start at the beginning of a line (e.g.
  # "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x...] moov atom not found" or
  # "<path>: Invalid data found when processing input"), except ffmpeg's
  # "    Last message repeated n times".
  defp json_line?(line), do: line =~ ~r/^\s*$|^[{}]\s*$|^\s+["{}\[\]]/

  defp finish(%__MODULE__{} = probe, path) do
    size = probe.size || file_size(path)
    mp4? = is_binary(probe.format_name) and String.contains?(probe.format_name, "mp4")
    %{probe | path: path, size: size, faststart?: mp4? and Mp4.faststart?(path)}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  @doc "Builds a probe result from ffprobe's decoded JSON output (`path` is not set)."
  @spec parse(map()) :: t()
  def parse(%{} = json) do
    format = json["format"] || %{}
    streams = json["streams"] || []

    video =
      Enum.find(streams, fn stream ->
        stream["codec_type"] == "video" and get_in(stream, ["disposition", "attached_pic"]) != 1
      end)

    audio = Enum.find(streams, &(&1["codec_type"] == "audio"))

    %__MODULE__{
      format_name: format["format_name"],
      duration:
        to_float(format["duration"]) || to_float(video && video["duration"]) ||
          to_float(audio && audio["duration"]),
      size: to_integer(format["size"]),
      bit_rate: to_integer(format["bit_rate"])
    }
    |> put_video(video)
    |> put_audio(audio)
  end

  defp put_video(probe, nil), do: probe

  defp put_video(probe, video) do
    rotation = rotation(video)
    {width, height} = {video["width"], video["height"]}

    {display_width, display_height} =
      if rem(abs(rotation), 180) == 90, do: {height, width}, else: {width, height}

    %{
      probe
      | has_video?: true,
        video_codec: video["codec_name"],
        video_profile: video["profile"],
        pix_fmt: video["pix_fmt"],
        width: width,
        height: height,
        display_width: display_width,
        display_height: display_height,
        rotation: rotation,
        fps: frame_rate(video["avg_frame_rate"]),
        video_bit_rate: to_integer(video["bit_rate"]),
        hdr?: video["color_transfer"] in @hdr_transfers
    }
  end

  defp put_audio(probe, nil), do: probe

  defp put_audio(probe, audio) do
    %{
      probe
      | has_audio?: true,
        audio_codec: audio["codec_name"],
        audio_channels: audio["channels"],
        audio_bit_rate: to_integer(audio["bit_rate"])
    }
  end

  defp rotation(stream) do
    stream
    |> Map.get("side_data_list", [])
    |> Enum.find_value(0, fn
      %{"side_data_type" => "Display Matrix", "rotation" => rotation} when is_number(rotation) ->
        round(rotation)

      _side_data ->
        nil
    end)
  end

  defp frame_rate(rate) when is_binary(rate) do
    with [numerator, denominator] <- String.split(rate, "/"),
         {numerator, ""} <- Integer.parse(numerator),
         {denominator, ""} when denominator > 0 <- Integer.parse(denominator),
         true <- numerator > 0 do
      numerator / denominator
    else
      _other -> nil
    end
  end

  defp frame_rate(_rate), do: nil

  defp to_float(value) when is_number(value), do: value / 1

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp to_float(_value), do: nil

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp to_integer(_value), do: nil

  @doc """
  Whether the `moov` box of an MP4/MOV file comes before its `mdat` box.

  Walks the top-level boxes (32-bit size and 4-byte type; a size of 1 means a
  64-bit size follows, 0 means the box extends to the end of the file). Unreadable
  or malformed files are reported as not fast start. See `Angler.Media.Probe.Mp4`.
  """
  @spec faststart?(Path.t()) :: boolean()
  defdelegate faststart?(path), to: Mp4
end
