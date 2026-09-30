defmodule Angler.Media.Ytdlp.Outcome do
  @moduledoc """
  Tells how a yt-dlp run ended: the downloaded file, or an `Angler.Media.Error` whose
  kind is classified from yt-dlp's `ERROR:` lines (and, for the generic "No video
  formats found", from the `WARNING:` lines that carry the actual reason), see
  `classify/1`.
  """
  alias Angler.Media
  alias Angler.Media.Error
  alias Angler.Media.Ytdlp.Progress

  @error_output_lines 30

  @doc """
  Interprets how a yt-dlp run ended from its exit status and last output lines.

  A `[result]` line means the video was downloaded (status 0, or 101 when
  `--max-downloads` stopped a multi-entry post). Status 0 or 101 without a result
  means the video was skipped (too long, live, larger than `--max-filesize`, no
  video) — unless yt-dlp printed `ERROR:` lines without a skip reason: a download
  that gave up (e.g. network errors, after which `--max-downloads` still ends the
  run with 101) is a failure. Failures are classified from the `ERROR:` lines.

  `opts` may hold `:max_duration` and `:max_source_bytes` for the messages.
  """
  @spec interpret(integer(), [String.t()], keyword()) :: {:ok, Path.t()} | {:error, Error.t()}
  def interpret(exit_status, lines, opts \\ []) do
    case Enum.find_value(lines, &result_path/1) do
      nil when exit_status in [0, 101] ->
        if errors?(lines) and not skip_reason?(lines),
          do: {:error, failure_error(exit_status, lines)},
          else: {:error, skipped_error(lines, opts)}

      nil ->
        {:error, failure_error(exit_status, lines)}

      path ->
        {:ok, path}
    end
  end

  defp result_path(line) do
    case Progress.parse_line(line) do
      {:result, path} -> path
      _other -> nil
    end
  end

  defp errors?(lines), do: Enum.any?(lines, &String.starts_with?(&1, "ERROR: "))

  defp skip_reason?(lines) do
    Enum.any?(lines, &String.contains?(&1, ["does not pass filter", "larger than max-filesize"]))
  end

  defp skipped_error(lines, opts) do
    output = error_output(lines)

    cond do
      filter_line = Enum.find(lines, &String.contains?(&1, "does not pass filter")) ->
        if live?(lines) do
          Error.new(:unsupported, "Live streams are not supported", output)
        else
          seconds = captured_integer(~r/duration<\?(\d+)/, filter_line) || opts[:max_duration]
          Error.new(:too_large, too_long_message(seconds), output)
        end

      size_line = Enum.find(lines, &String.contains?(&1, "larger than max-filesize")) ->
        limit = captured_integer(~r/> (\d+) bytes/, size_line) || opts[:max_source_bytes]
        Error.new(:too_large, too_big_message(limit), output)

      true ->
        Error.new(:unsupported, "No video found at this link", output)
    end
  end

  defp live?(lines) do
    Enum.any?(lines, fn line ->
      match?({:meta, %{"is_live" => true}}, Progress.parse_line(line))
    end)
  end

  defp captured_integer(regex, line) do
    case Regex.run(regex, line) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  @doc ~S'The message for a video longer than `seconds`, e.g. "Video is longer than 30 minutes".'
  @spec too_long_message(non_neg_integer() | nil) :: String.t()
  def too_long_message(nil), do: "Video is too long"

  def too_long_message(seconds),
    do: "Video is longer than #{Media.format_duration(seconds * 1_000)}"

  @doc ~S'The message for a source larger than `bytes`, e.g. "Source file is larger than 1024 MB".'
  @spec too_big_message(non_neg_integer() | nil) :: String.t()
  def too_big_message(nil), do: "Source file is too large"
  def too_big_message(bytes), do: "Source file is larger than #{Media.format_mb(bytes)}"

  @doc """
  The error for a yt-dlp run that failed with `exit_status` (without a result),
  classified from its `ERROR:` lines like `interpret/3` does.
  """
  @spec failure(integer(), [String.t()]) :: Error.t()
  def failure(exit_status, lines), do: failure_error(exit_status, lines)

  defp failure_error(exit_status, lines) do
    errors = for "ERROR: " <> message <- lines, do: message

    {kind, message} =
      failure_reason(errors, lines) || {:internal, status_message(exit_status, lines)}

    Error.new(kind, clean_message(message), error_output(lines))
  end

  # The first error with a specific reason wins. The generic "No video formats found"
  # error comes with --ignore-no-formats-error, which turns the real reason ("This
  # video is unavailable", "Sign in to confirm your age", HTTP 429, ...) into a warning.
  defp failure_reason(errors, lines) do
    {generic, specific} = Enum.split_with(errors, &no_formats?/1)

    cond do
      reason = Enum.find_value(specific, &reason(&1, [:unsupported, :transient, :unavailable])) ->
        reason

      generic != [] ->
        warning_reason(lines) || {:unsupported, "No video found at this link"}

      errors != [] ->
        {:internal, List.last(errors)}

      true ->
        nil
    end
  end

  defp warning_reason(lines) do
    Enum.find_value(lines, fn
      "WARNING: " <> message -> reason(message, [:unavailable, :transient])
      _line -> nil
    end)
  end

  defp reason(message, kinds) do
    kind = classify(message)
    if kind in kinds, do: {kind, message}
  end

  defp no_formats?(message),
    do: message =~ ~r/no video formats found|requested format is not available/i

  defp status_message(exit_status, lines) do
    message = "yt-dlp exited with status #{exit_status}"

    case lines |> Enum.reject(&progress_line?/1) |> List.last() do
      nil -> message
      last -> message <> ": " <> last
    end
  end

  @doc """
  Classifies a yt-dlp error message (without the `ERROR: ` prefix) into an error kind:

    * `:unsupported` - no extractor for the URL or no video in the post
    * `:transient` - rate limits, timeouts, network and server errors
    * `:unavailable` - private, removed, login/age/geo restricted, blocked content
    * `:internal` - anything else, e.g. a broken extractor ("please report this issue"),
      which a yt-dlp update usually fixes

  Rate limits and server errors (HTTP 5xx) win over the login hints and reason
  phrases ("Service Unavailable") that accompany them; HTTP 401/404/410 mean
  unavailable even when the webpage download failed.
  """
  @spec classify(String.t()) :: :unsupported | :transient | :unavailable | :internal
  def classify(message) do
    cond do
      matches_any?(message, unsupported_patterns()) -> :unsupported
      matches_any?(message, overload_patterns()) -> :transient
      matches_any?(message, unavailable_patterns()) -> :unavailable
      matches_any?(message, network_patterns()) -> :transient
      true -> :internal
    end
  end

  defp matches_any?(message, patterns), do: Enum.any?(patterns, &Regex.match?(&1, message))

  defp unsupported_patterns do
    [
      ~r/unsupported url/i,
      ~r/no video formats found/i,
      ~r/requested format is not available/i,
      ~r/\bno video\b/i,
      ~r/is not a video/i
    ]
  end

  defp overload_patterns do
    [~r/HTTP Error 429/, ~r/too many requests/i, ~r/rate.?limit/i, ~r/HTTP Error 5\d\d/]
  end

  defp unavailable_patterns do
    [
      ~r/HTTP Error (401|404|410)\b/,
      ~r/\bprivate\b/i,
      ~r/\blog ?in(to)?\b|\blogged.in\b|\bsign in\b|authenticat/i,
      ~r/\bcookies\b/i,
      ~r/registered users|members.only/i,
      ~r/not available|unavailable/i,
      ~r/\bremoved\b|\bdeleted\b/i,
      ~r/\bDRM\b/,
      ~r/geo.?restrict|your (location|country)/i,
      ~r/\bage\b|age.?restrict|inappropriate/i,
      ~r/restricted video/i,
      ~r/copyright/i,
      ~r/\bblocked\b/i,
      ~r/live event|premieres in/i
    ]
  end

  defp network_patterns do
    [
      ~r/timed? ?out/i,
      ~r/connection (reset|refused|aborted)/i,
      ~r/temporary failure in name resolution|name or service not known|nodename nor servname/i,
      ~r/failed to resolve|getaddrinfo/i,
      ~r/unable to connect|tunnel connection failed/i,
      ~r/network is unreachable/i,
      ~r/unable to download/i,
      ~r/IncompleteRead/i,
      ~r/remote end closed/i
    ]
  end

  @doc ~S'Removes the "please report this issue" boilerplate from a yt-dlp message.'
  @spec clean_message(String.t()) :: String.t()
  def clean_message(message) do
    message
    |> String.split(~r/;?\s*please report this issue/i, parts: 2)
    |> hd()
    |> String.trim()
  end

  @doc "The last #{@error_output_lines} output lines without progress lines, for the dashboard."
  @spec error_output([String.t()]) :: String.t()
  def error_output(lines) do
    lines
    |> Enum.reject(&progress_line?/1)
    |> Enum.take(-@error_output_lines)
    |> Enum.join("\n")
  end

  defp progress_line?(line), do: String.starts_with?(line, ["[progress]", "[postprocess]"])
end
