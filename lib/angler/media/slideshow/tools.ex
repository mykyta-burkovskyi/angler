defmodule Angler.Media.Slideshow.Tools do
  @moduledoc """
  Runs ffmpeg and ffprobe for slideshows through `Angler.Media.Command` (bounded
  runtime, killed with the caller), using the configured executables.

  Results tell apart a tool that ran and failed on its input (`{:failed, error}`,
  e.g. an unreadable image, which callers may skip) from failures to run it at all
  or in time (`{:error, error}`: not installed, timeout), which fail the job.
  """
  alias Angler.Media
  alias Angler.Media.{Command, Error}

  @error_output_lines 30

  @type result(ok) :: ok | {:failed, Error.t()} | {:error, Error.t()}

  @doc "Runs ffmpeg. Options: `:timeout` (required, ms), `:on_line`."
  @spec ffmpeg([String.t()], keyword()) :: result(:ok)
  def ffmpeg(args, opts) do
    with {:ok, _lines} <- run("ffmpeg", Media.config(:ffmpeg_path, "ffmpeg"), args, opts), do: :ok
  end

  @doc "Runs ffprobe with JSON output and decodes it. Options: `:timeout` (required, ms)."
  @spec ffprobe_json([String.t()], keyword()) :: result({:ok, map()})
  def ffprobe_json(args, opts) do
    opts = Keyword.put(opts, :max_lines, 10_000)

    with {:ok, lines} <- run("ffprobe", Media.config(:ffprobe_path, "ffprobe"), args, opts) do
      # Decoder warnings may precede the JSON document, which starts with a "{" line.
      json = lines |> Enum.drop_while(&(String.trim(&1) != "{")) |> Enum.join("\n")

      case Jason.decode(json) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _other -> {:failed, Error.new(:internal, "Could not parse the ffprobe output")}
      end
    end
  end

  defp run(name, executable, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case Command.run(executable, args, opts) do
      {:ok, %{exit_status: 0, output: lines}} ->
        {:ok, lines}

      {:ok, %{exit_status: status, output: lines}} ->
        messages = Enum.reject(lines, &(progress_line?(&1) or json_line?(&1)))
        detail = if messages == [], do: "", else: ": " <> List.last(messages)
        {:failed, Error.new(:internal, "#{name} failed (exit #{status})" <> detail, tail(lines))}

      {:error, :timeout, lines} ->
        message = "#{name} took longer than #{Media.format_duration(timeout)}"
        {:error, Error.new(:timeout, message, tail(lines))}

      {:error, :enoent} ->
        {:error, Error.new(:internal, "#{name} not found")}

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not start #{name}: #{inspect(reason)}")}

      {:error, reason, lines} ->
        {:error, Error.new(:internal, "#{name} failed: #{inspect(reason)}", tail(lines))}
    end
  end

  defp progress_line?(line), do: Regex.match?(~r/^[a-z0-9_]+=/, line)

  # ffprobe prints its (empty) JSON document even when it fails.
  defp json_line?(line), do: Regex.match?(~r/^\s*([\[\]{}"]|$)/, line)

  defp tail(lines) do
    lines
    |> Enum.reject(&progress_line?/1)
    |> Enum.take(-@error_output_lines)
    |> Enum.join("\n")
  end
end
