defmodule Angler.Media.Ytdlp.Progress do
  @moduledoc """
  Parses the lines yt-dlp prints (see `Angler.Media.Ytdlp`) and watches a running
  download: reports its progress and stops it once it takes more disk space than the
  source size limit.

  `--max-filesize` alone does not bound a download: yt-dlp checks it only against a
  `Content-Length` header, per format of a merged download and per fragment of an
  HLS/DASH download. And yt-dlp prints no progress while ffmpeg downloads an HLS
  stream for it (it does so for encryption methods its own downloader does not
  support), so the size of the entry directory, which holds every partial and
  finished part, is compared with the limit every second rather than on progress
  lines.
  """
  alias Angler.Media

  @typedoc "A progress line: bytes so far, total (or estimate), bytes/second and seconds left."
  @type progress :: %{
          status: String.t(),
          downloaded: number() | nil,
          total: number() | nil,
          speed: number() | nil,
          eta: number() | nil
        }

  @doc """
  Returns the `on_line` handler that reports progress to `on_progress`
  (`t:Angler.Media.progress_fun/0`), or nil without one.
  """
  @spec handler(Angler.Media.progress_fun() | nil) :: (String.t() -> any()) | nil
  def handler(nil), do: nil

  def handler(on_progress) do
    report = Media.throttle(on_progress)

    fn line ->
      case parse_line(line) do
        {:progress, progress} ->
          report.(progress_update(progress))

        {:postprocess, "started", "Merger"} ->
          on_progress.(%{percent: nil, detail: "Merging formats"})

        _other ->
          :ok
      end
    end
  end

  @doc """
  Returns the `on_tick` function (see `Angler.Media.Command.run/3`) that stops a
  download into `dir` once the directory takes more than `limit` bytes, or nil
  without a limit. It throws `{:source_too_large, bytes}`, which makes
  `Angler.Media.Command` stop yt-dlp and throw it again in the caller.
  """
  @spec size_guard(Path.t(), pos_integer() | nil) :: (-> any()) | nil
  def size_guard(_dir, nil), do: nil

  def size_guard(dir, limit) do
    fn ->
      size = disk_usage(dir)
      if size > limit, do: throw({:source_too_large, size})
    end
  end

  @doc "Bytes taken by the regular files under `path` (symbolic links are not followed)."
  @spec disk_usage(Path.t()) :: non_neg_integer()
  def disk_usage(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> Enum.reduce(names, 0, &(disk_usage(Path.join(path, &1)) + &2))
          {:error, _reason} -> 0
        end

      _other ->
        0
    end
  end

  @doc "Parses one line of yt-dlp output (see `Angler.Media.Ytdlp`)."
  @spec parse_line(String.t()) ::
          {:progress, progress()}
          | {:postprocess, status :: String.t(), postprocessor :: String.t()}
          | {:meta, map()}
          | {:result, Path.t()}
          | :other
  def parse_line("[progress] " <> rest) do
    case String.split(rest, " ") do
      [status, downloaded, total, speed, eta] ->
        {:progress,
         %{
           status: status,
           downloaded: number(downloaded),
           total: number(total),
           speed: number(speed),
           eta: number(eta)
         }}

      _other ->
        :other
    end
  end

  def parse_line("[postprocess] " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [status, postprocessor] -> {:postprocess, status, postprocessor}
      _other -> :other
    end
  end

  def parse_line("[meta] " <> json) do
    case Jason.decode(json) do
      {:ok, %{} = meta} -> {:meta, meta}
      _other -> :other
    end
  end

  def parse_line("[result] " <> json) do
    case Jason.decode(json) do
      {:ok, path} when is_binary(path) and path != "" -> {:result, path}
      _other -> :other
    end
  end

  def parse_line(_line), do: :other

  defp number(value) do
    case Float.parse(value) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _other -> nil
    end
  end

  @doc """
  Turns a progress line into a progress update:
  `%{percent: 27.3, detail: "12.3 MB of 45.0 MB · 2.1 MB/s · 0:12 left"}`.
  """
  @spec progress_update(progress()) :: %{percent: float() | nil, detail: String.t()}
  def progress_update(%{downloaded: downloaded, total: total, speed: speed, eta: eta} = progress) do
    percent =
      if is_number(downloaded) and is_number(total) and total > 0,
        do: min(downloaded / total * 100, 100.0)

    size =
      cond do
        is_number(downloaded) and is_number(total) ->
          "#{format_bytes(downloaded)} of #{format_bytes(total)}"

        is_number(downloaded) ->
          format_bytes(downloaded)

        true ->
          nil
      end

    parts = [
      size,
      is_number(speed) && format_bytes(speed) <> "/s",
      (progress.status == "downloading" and is_number(eta)) && format_eta(eta) <> " left"
    ]

    %{percent: percent, detail: parts |> Enum.filter(&is_binary/1) |> Enum.join(" · ")}
  end

  defp format_bytes(bytes) when bytes >= 1_000_000_000, do: decimal(bytes / 1.0e9) <> " GB"
  defp format_bytes(bytes) when bytes >= 1_000_000, do: decimal(bytes / 1.0e6) <> " MB"
  defp format_bytes(bytes) when bytes >= 1_000, do: "#{round(bytes / 1_000)} kB"
  defp format_bytes(bytes), do: "#{round(bytes)} B"

  defp decimal(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp format_eta(seconds) do
    seconds = round(seconds)
    {hours, minutes, secs} = {div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    if hours > 0, do: "#{hours}:#{pad.(minutes)}:#{pad.(secs)}", else: "#{minutes}:#{pad.(secs)}"
  end
end
