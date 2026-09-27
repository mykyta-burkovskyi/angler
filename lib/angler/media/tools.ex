defmodule Angler.Media.Tools do
  @moduledoc """
  Versions of the external tools (yt-dlp, ffmpeg, deno) shown on the dashboard,
  through `Angler.Media.tool_versions/0`.

  Detecting them runs every tool, so the result is cached in `:persistent_term`
  for 10 minutes; `Angler.Media.Updater` drops the cache after updating yt-dlp.
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Command, Ytdlp}

  @versions_key {__MODULE__, :versions}
  @versions_ttl :timer.minutes(10)
  @version_timeout :timer.seconds(15)

  @doc "See `Angler.Media.tool_versions/0`."
  @spec versions() :: %{String.t() => String.t() | nil}
  def versions do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@versions_key, nil) do
      {checked_at, versions} when now - checked_at < @versions_ttl ->
        versions

      _ ->
        versions = detect_versions()
        :persistent_term.put(@versions_key, {now, versions})
        versions
    end
  end

  @doc "See `Angler.Media.forget_tool_versions/0`."
  @spec forget_versions() :: :ok
  def forget_versions do
    :persistent_term.erase(@versions_key)
    :ok
  end

  defp detect_versions do
    [
      {"yt-dlp", Ytdlp.executable(), ["--version"]},
      {"ffmpeg", Media.config(:ffmpeg_path, "ffmpeg"), ["-version"]},
      {"deno", "deno", ["--version"]}
    ]
    |> Task.async_stream(
      fn {tool, executable, args} -> {tool, version(tool, executable, args)} end,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp version(tool, executable, args) do
    case Command.run(executable, args, timeout: @version_timeout, env: Media.tool_env()) do
      {:ok, %{exit_status: 0, output: [first_line | _]}} -> parse_version(tool, first_line)
      _other -> nil
    end
  rescue
    error ->
      Logger.warning("Could not get the #{tool} version: #{Exception.message(error)}")
      nil
  end

  @doc "See `Angler.Media.parse_version/2`."
  @spec parse_version(String.t(), String.t()) :: String.t() | nil
  def parse_version("ffmpeg", line) do
    case Regex.run(~r/^ffmpeg version (\S+)/, line) do
      [_, token] ->
        case Regex.run(~r/^n?(\d+(?:\.\d+)+)/, token) do
          [_, version] -> version
          nil -> token
        end

      nil ->
        nil
    end
  end

  def parse_version("deno", line) do
    case String.split(line) do
      ["deno", version | _] -> version
      _other -> nil
    end
  end

  def parse_version(_tool, line) do
    case String.trim(line) do
      "" -> nil
      version -> version
    end
  end
end
