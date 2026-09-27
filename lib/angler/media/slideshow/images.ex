defmodule Angler.Media.Slideshow.Images do
  @moduledoc """
  Probes slideshow images with ffprobe (see `Angler.Media.Slideshow.Commands.probe_args/1`).

  An image's dimensions are those of its first decoded frame, swapped when the
  frame carries a ±90° rotation (EXIF orientation, which ffmpeg applies when
  decoding), or those of the whole tile grid for HEIC/AVIF (read as stream group
  `g:0`). Images ffprobe can't read, without a decodable picture (truncated or
  garbage files probe as 0x0) or larger than 64 megapixels are skipped; the
  slideshow is made from the rest.
  """
  require Logger

  alias Angler.Media.Error
  alias Angler.Media.Slideshow.{Commands, Tools}

  @max_pixels 64_000_000
  @timeout :timer.seconds(30)
  @alpha_formats ~w(rgba bgra argb abgr ya8 ya16be ya16le rgba64be rgba64le yuva420p yuva422p
                    yuva444p pal8 gbrap gbrap16be gbrap16le)

  @doc """
  Probes `paths` (in parallel) and returns the usable images in order, as
  `t:Angler.Media.Slideshow.Commands.image/0`. Fails only when ffprobe can't run.
  """
  @spec probe([Path.t()]) :: {:ok, [Commands.image()]} | {:error, Error.t()}
  def probe(paths) do
    paths
    |> Task.async_stream(&{&1, probe_one(&1)},
      max_concurrency: concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while([], fn
      {:ok, {_path, {:ok, image}}}, images ->
        {:cont, [image | images]}

      {:ok, {path, {:skip, reason}}}, images ->
        Logger.warning("Skipping slideshow image #{Path.basename(path)}: #{reason}")
        {:cont, images}

      {:ok, {_path, {:error, error}}}, _images ->
        {:halt, {:error, error}}
    end)
    |> case do
      {:error, error} -> {:error, error}
      images -> {:ok, Enum.reverse(images)}
    end
  end

  @doc "How many ffmpeg/ffprobe runs a slideshow step starts at once."
  @spec concurrency() :: pos_integer()
  def concurrency, do: min(System.schedulers_online(), 4)

  defp probe_one(path) do
    case Tools.ffprobe_json(Commands.probe_args(path), timeout: @timeout) do
      {:ok, json} ->
        with {:ok, image} <- parse(json), do: {:ok, Map.put(image, :path, path)}

      {:failed, error} ->
        {:skip, error.message}

      {:error, %Error{kind: :timeout} = error} ->
        {:skip, error.message}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Reads an image's dimensions, filtergraph input label and whether it has an alpha
  channel from ffprobe's JSON, or why it can't be used.
  """
  @spec parse(map()) ::
          {:ok,
           %{width: pos_integer(), height: pos_integer(), label: String.t(), alpha: boolean()}}
          | {:skip, String.t()}
  def parse(json) do
    case List.first(list(json["streams"])) do
      %{} = stream ->
        {width, height, label} = dimensions(json, stream)

        cond do
          not (positive?(width) and positive?(height)) ->
            {:skip, "no decodable picture"}

          width * height > @max_pixels ->
            {:skip, "#{width}x#{height} is larger than 64 megapixels"}

          true ->
            {:ok,
             %{
               width: width,
               height: height,
               label: label,
               alpha: stream["pix_fmt"] in @alpha_formats
             }}
        end

      nil ->
        {:skip, "no picture"}
    end
  end

  defp dimensions(json, stream) do
    grid =
      Enum.find_value(list(json["stream_groups"]), fn
        %{"type" => "Tile Grid", "components" => [%{"width" => w, "height" => h} | _]} -> {w, h}
        _group -> nil
      end)

    case grid do
      {width, height} ->
        {width, height, "g:0"}

      nil ->
        frame = List.first(list(json["frames"])) || stream
        {width, height} = {frame["width"], frame["height"]}

        if rem(abs(rotation(frame)), 180) == 90,
          do: {height, width, "v:0"},
          else: {width, height, "v:0"}
    end
  end

  defp rotation(frame) do
    Enum.find_value(list(frame["side_data_list"]), 0, fn
      %{"rotation" => rotation} when is_number(rotation) -> round(rotation)
      _side_data -> nil
    end)
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp positive?(value), do: is_integer(value) and value > 0
end
