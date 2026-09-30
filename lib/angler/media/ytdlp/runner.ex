defmodule Angler.Media.Ytdlp.Runner do
  @moduledoc """
  Runs yt-dlp in an entry directory for `Angler.Media.Ytdlp` (downloads and
  metadata), the same way every time:

    * through its own `Angler.Media.EgressProxy` unless private networks are
      allowed (`--proxy`, and the proxy variables for the tools yt-dlp starts)
    * with a private, writable copy of the configured cookies file, deleted
      afterwards together with the `tmp` directory
    * with the tool environment (`Angler.Media.tool_env/0`) and the executable
      `Angler.Media.Ytdlp.executable/0` chooses
  """
  alias Angler.Media
  alias Angler.Media.{Command, Egress, EgressProxy, Error, Ytdlp}

  require Logger

  @doc """
  Runs yt-dlp in `dir` with the arguments `build_args` returns for the run's
  `:cookies` (path of the cookies copy, or nil), `:cache_dir` and `:proxy` (proxy
  URL, or nil). `command_opts` go to `Angler.Media.Command.run/3` (`:cd` and
  `:env` are set here).

  Returns the command's result and the hosts the proxy refused. A value thrown by
  an `:on_line`/`:on_tick` callback is thrown again after cleaning up.
  """
  @spec run(Path.t(), (keyword() -> [String.t()]), keyword()) ::
          {:ok, Command.result(), blocked :: [String.t()]} | {:error, Error.t()}
  def run(dir, build_args, command_opts) do
    case start_proxy() do
      {:ok, proxy} ->
        try do
          result = run_command(dir, proxy && proxy.url, build_args, command_opts)
          {:ok, result, stop_proxy(proxy)}
        after
          stop_proxy(proxy)
        end

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not start the download proxy: #{inspect(reason)}")}
    end
  end

  defp start_proxy do
    if Egress.private_networks_allowed?(), do: {:ok, nil}, else: EgressProxy.start()
  end

  defp stop_proxy(nil), do: []
  defp stop_proxy(proxy), do: EgressProxy.stop(proxy)

  defp run_command(dir, proxy_url, build_args, command_opts) do
    cache_dir = Media.cache_dir()
    File.mkdir_p(cache_dir)
    cookies = copy_cookies(dir)

    try do
      args = build_args.(cookies: cookies, cache_dir: cache_dir, proxy: proxy_url)
      Command.run(Ytdlp.executable(), args, [cd: dir, env: env(proxy_url)] ++ command_opts)
    after
      if cookies, do: File.rm(cookies)
      File.rm_rf(Path.join(dir, "tmp"))
    end
  end

  # yt-dlp ignores proxy variables once --proxy is given; they are set for the tools
  # it starts (ffmpeg honours http_proxy and no_proxy, deno HTTPS_PROXY).
  defp env(nil), do: Media.tool_env()

  defp env(proxy_url) do
    Media.tool_env() ++
      Enum.map(~w(http_proxy HTTP_PROXY https_proxy HTTPS_PROXY), &{&1, proxy_url}) ++
      Enum.map(~w(no_proxy NO_PROXY all_proxy ALL_PROXY), &{&1, nil})
  end

  # yt-dlp writes the cookie jar back when it exits, so it gets a private, writable
  # copy of the configured file for every run. The copy is made readable by the app
  # user only before the secrets are written into it; File.copy/2 (unlike File.cp/2)
  # keeps the mode of an existing destination.
  defp copy_cookies(dir) do
    target = Path.join(dir, "cookies.txt")

    with source when is_binary(source) <- Media.config(:cookies_file),
         :ok <- File.write(target, ""),
         :ok <- File.chmod(target, 0o600),
         {:ok, _bytes} <- File.copy(source, target) do
      target
    else
      nil ->
        nil

      {:error, reason} ->
        File.rm(target)
        Logger.warning("Ignoring the yt-dlp cookies file: #{:file.format_error(reason)}")
        nil
    end
  end

  @doc """
  Reports a failed run whose proxy refused hosts as such (`:unavailable`), since
  that is usually why it failed; `:too_large` errors are kept.
  """
  @spec blocked(Error.t(), [String.t()]) :: Error.t()
  def blocked(%Error{kind: kind} = error, blocked) when blocked != [] and kind != :too_large do
    message =
      "Downloads may not reach private network addresses (#{Enum.join(blocked, ", ")}); " <>
        "set ALLOW_PRIVATE_NETWORK_DOWNLOADS=true to allow them"

    %{error | kind: :unavailable, message: message}
  end

  def blocked(error, _blocked), do: error
end
