defmodule Angler.Media.Ytdlp.Metadata do
  @moduledoc """
  Reads what yt-dlp knows about each item of a post, without downloading anything.
  `Angler.Media.Instagram` falls back to it when Instagram refuses its own
  logged-out requests, and uses it for posts hidden from logged-out visitors: this
  is how the cookies file reaches Instagram (yt-dlp has a maintained logged-in path
  and impersonates a browser).

  yt-dlp runs like a download (`Angler.Media.Ytdlp.Runner`: egress proxy, cookies
  copy) with `--skip-download --ignore-no-formats-error` (photos have no formats)
  and prints the info dict of every item as one JSON line into `items.jsonl` in
  the entry directory (`--print-to-file`; output lines are capped at 64 KB, info
  dicts are larger). Carousel items carry `playlist_index`; a single photo or
  video is one line. The file is read and removed. Failures are classified by
  `Angler.Media.Ytdlp.Outcome`.
  """
  alias Angler.Media
  alias Angler.Media.Error
  alias Angler.Media.Ytdlp.{Outcome, Runner}

  @default_timeout :timer.minutes(2)
  @items_file "items.jsonl"
  @max_items_bytes 16_000_000

  @doc """
  Reads the items of the post at `url`, running yt-dlp in `dir`: `{:ok, entries}`
  (at least one info dict, in the order yt-dlp printed them) or an error:
  yt-dlp's (as `Angler.Media.Ytdlp.Outcome` classifies it), `:unsupported` when
  it found nothing, `:timeout` after `opts[:timeout]` milliseconds (default 2
  minutes).
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def run(url, dir, opts \\ []) do
    dir = Path.expand(dir)
    items = Path.join(dir, @items_file)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    File.mkdir_p(dir)
    File.rm(items)

    try do
      case Runner.run(dir, &args(url, dir, &1), timeout: timeout) do
        {:ok, result, blocked} ->
          with {:error, error} <- outcome(result, items, timeout),
               do: {:error, Runner.blocked(error, blocked)}

        {:error, error} ->
          {:error, error}
      end
    after
      File.rm(items)
    end
  end

  @doc """
  Command line arguments for reading `url` in `dir`. Options: `:cookies` (path of
  the per-run cookies copy), `:cache_dir` and `:proxy` (URL of the
  `Angler.Media.EgressProxy`). The URL comes last, after `--`.
  """
  @spec args(String.t(), Path.t(), keyword()) :: [String.t()]
  def args(url, dir, opts) do
    items = dir |> Path.join(@items_file) |> String.replace("%", "%%")

    List.flatten([
      ~w(--ignore-config --skip-download --ignore-no-formats-error --no-warnings --color never),
      ["-P", "home:" <> dir, "-o", "%(id)s"],
      ~w(--socket-timeout 30 --extractor-retries 3),
      ["--print-to-file", "video:%()j", items],
      option("--cache-dir", opts[:cache_dir] && Path.join(opts[:cache_dir], "yt-dlp")),
      option("--cookies", opts[:cookies]),
      option("--proxy", opts[:proxy]),
      ["--", url]
    ])
  end

  defp option(_flag, nil), do: []
  defp option(flag, value), do: [flag, value]

  defp outcome({:ok, %{exit_status: 0}}, items, _timeout) do
    case read(items) do
      {:ok, [_ | _] = entries} -> {:ok, entries}
      {:ok, []} -> {:error, Error.new(:unsupported, "yt-dlp found nothing at this link")}
      {:error, message} -> {:error, Error.new(:internal, message)}
    end
  end

  defp outcome({:ok, %{exit_status: status, output: lines}}, _items, _timeout),
    do: {:error, Outcome.failure(status, lines)}

  defp outcome({:error, :timeout, lines}, _items, timeout) do
    message = "Reading the post took longer than #{Media.format_duration(timeout)}"
    {:error, Error.new(:timeout, message, Outcome.error_output(lines))}
  end

  defp outcome({:error, :enoent}, _items, _timeout),
    do: {:error, Error.new(:internal, "yt-dlp not found")}

  defp outcome({:error, reason}, _items, _timeout),
    do: {:error, Error.new(:internal, "Could not start yt-dlp: #{inspect(reason)}")}

  defp outcome({:error, reason, lines}, _items, _timeout) do
    message = "yt-dlp failed: #{inspect(reason)}"
    {:error, Error.new(:internal, message, Outcome.error_output(lines))}
  end

  defp read(path) do
    with {:ok, %File.Stat{size: size}} when size <= @max_items_bytes <- File.stat(path),
         {:ok, contents} <- File.read(path) do
      {:ok, contents |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)}
    else
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %File.Stat{}} ->
        {:error, "yt-dlp printed more than 16 MB of metadata"}

      {:error, reason} ->
        {:error, "Could not read yt-dlp's metadata: #{:file.format_error(reason)}"}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> [entry]
      _other -> []
    end
  end
end
