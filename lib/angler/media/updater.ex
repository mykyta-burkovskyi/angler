defmodule Angler.Media.Updater do
  @moduledoc """
  Keeps a self-updating copy of yt-dlp when `ytdlp_update_channel` is set
  (`"stable"` or `"nightly"`, the channel yt-dlp recommends for regular users since
  sites change often).

  The binary shipped with the image is not writable by the app user, so on start
  the configured yt-dlp is copied to `<data_dir>/bin/yt-dlp` (on the data volume),
  which `Angler.Media.Ytdlp.executable/0` uses from then on. Shortly after boot and
  then every 24 hours it runs `yt-dlp --update-to <channel>`; `update_now/0` (the
  dashboard button) runs an update right away. Updates run one at a time inside this
  process.

  yt-dlp swaps in the new version by renaming files (downloads that are running keep
  the old one) and restores the executable bit only afterwards, so an update that is
  cut short can leave the copy missing or not executable, and
  `Angler.Media.Ytdlp.executable/0` then falls back to the configured binary. On
  start and before every update the copy is installed again when it is missing, does
  not run, or is older than the configured binary (a newer image while updates keep
  failing).

  When no channel is configured the updater does not start and the configured
  yt-dlp is used as is.
  """
  use GenServer

  require Logger

  alias Angler.Media
  alias Angler.Media.{Command, Ytdlp}

  @initial_delay :timer.minutes(1)
  @interval :timer.hours(24)
  # The standalone binary is about 37 MB, which slow links need minutes for.
  @update_timeout :timer.minutes(10)
  @version_timeout :timer.seconds(30)
  # Longer than an update: installing (two version checks), updating, checking.
  @call_timeout @update_timeout + 4 * @version_timeout
  @disabled "auto-update is disabled (set YTDLP_UPDATE_CHANNEL)"

  @doc """
  Starts the updater, or returns `:ignore` when auto-update is disabled.

  Options (defaults in parentheses): `:channel` (the configured
  `ytdlp_update_channel`), `:initial_delay` (1 minute) and `:interval` (24 hours),
  in milliseconds or `:infinity`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :channel, Media.config(:ytdlp_update_channel)) do
      channel when channel in [nil, ""] ->
        :ignore

      channel ->
        GenServer.start_link(__MODULE__, Keyword.put(opts, :channel, channel), name: __MODULE__)
    end
  end

  @doc """
  Updates yt-dlp now and returns its version, or `{:error, reason}` (also when
  auto-update is disabled).
  """
  @spec update_now() :: {:ok, String.t()} | {:error, String.t()}
  def update_now do
    GenServer.call(__MODULE__, :update, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, @disabled}
    :exit, {:timeout, _} -> {:error, "the yt-dlp update is taking too long; check the logs"}
    :exit, _reason -> {:error, "the yt-dlp updater stopped; check the logs"}
  end

  @impl true
  def init(opts) do
    state = %{
      channel: Keyword.fetch!(opts, :channel),
      initial_delay: Keyword.get(opts, :initial_delay, @initial_delay),
      interval: Keyword.get(opts, :interval, @interval)
    }

    {:ok, state, {:continue, :install}}
  end

  @impl true
  def handle_continue(:install, state) do
    with {:error, reason} <- install(), do: Logger.warning(reason)
    schedule(state.initial_delay)
    {:noreply, state}
  end

  @impl true
  def handle_info(:update, state) do
    update(state.channel)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:update, _from, state) do
    {:reply, update(state.channel), state}
  end

  defp schedule(:infinity), do: :ok
  defp schedule(delay), do: Process.send_after(self(), :update, delay)

  # Copies the configured yt-dlp to the managed location unless a working copy that
  # is at least as new exists. The copy is renamed into place so a download never
  # runs a half-written file.
  defp install do
    managed = Ytdlp.managed_path()

    with {:ok, source} <- Command.find_executable(Media.config(:ytdlp_path, "yt-dlp")),
         false <- current?(managed, source),
         tmp = managed <> ".tmp",
         :ok <- File.mkdir_p(Path.dirname(managed)),
         :ok <- File.cp(source, tmp),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, managed) do
      Logger.info("Installed a self-updating copy of yt-dlp at #{managed}")
      :ok
    else
      true ->
        :ok

      {:error, reason} ->
        File.rm(managed <> ".tmp")

        if Ytdlp.managed_copy_usable?() do
          :ok
        else
          {:error,
           "could not install a self-updating copy of yt-dlp: #{:file.format_error(reason)}"}
        end
    end
  end

  defp current?(managed, source) do
    Ytdlp.managed_copy_usable?() and
      case {version(managed), version(source)} do
        {{:ok, installed}, {:ok, bundled}} -> version_key(installed) >= version_key(bundled)
        {{:ok, _installed}, {:error, _reason}} -> true
        {{:error, _reason}, _bundled} -> false
      end
  end

  defp version(executable) do
    case run(executable, ["--version"], @version_timeout) do
      {:ok, [version | _]} -> {:ok, String.trim(version)}
      {:ok, []} -> {:error, "yt-dlp --version printed nothing"}
      {:error, reason} -> {:error, reason}
    end
  end

  # "2026.08.19" (stable) and "2026.09.20.000000" (nightly) compare as integer lists.
  defp version_key(version) do
    version
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {number, _rest} -> number
        :error -> 0
      end
    end)
  end

  defp update(channel) do
    managed = Ytdlp.managed_path()

    with :ok <- install(),
         {:ok, output} <- run(managed, ["--update-to", channel], @update_timeout),
         {:ok, version} <- version(managed) do
      Media.forget_tool_versions()
      Logger.info("yt-dlp #{version} (#{channel}): #{List.last(output)}")
      {:ok, version}
    else
      {:error, reason} -> update_failed(reason)
    end
  end

  defp update_failed(reason) do
    Logger.warning("yt-dlp update failed: #{reason}")
    {:error, "yt-dlp update failed: #{reason}"}
  end

  defp run(executable, args, timeout) do
    case Command.run(executable, args, timeout: timeout, env: Media.tool_env()) do
      {:ok, %{exit_status: 0, output: output}} ->
        {:ok, output}

      {:ok, %{exit_status: status, output: output}} ->
        error = Enum.find(output, &String.starts_with?(&1, "ERROR: ")) || List.last(output)
        {:error, "exit status #{status}: #{error}"}

      {:error, :timeout, _output} ->
        {:error, "timed out"}

      {:error, reason} ->
        {:error, inspect(reason)}

      {:error, reason, _output} ->
        {:error, inspect(reason)}
    end
  end
end
