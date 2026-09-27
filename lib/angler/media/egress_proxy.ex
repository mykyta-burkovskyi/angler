defmodule Angler.Media.EgressProxy do
  @moduledoc """
  A small HTTP proxy on the loopback interface that keeps downloads away from
  private networks (server-side request forgery).

  The host allowlist only sees the posted link, but yt-dlp follows HTTP redirects,
  meta refreshes and extractors that hand a post over to another site (a Reddit link
  post, a tweet's link) to any address. So every yt-dlp run gets its own proxy
  (`--proxy`), which also covers fragment downloads and the ffmpeg yt-dlp starts for
  some formats (it passes the proxy on through `http_proxy`). For each request the
  proxy resolves the host itself, refuses it unless all of its addresses are public
  (`Angler.Media.Egress.check/1`), and connects to exactly the addresses it checked,
  so DNS rebinding cannot swap in another one.

  It understands `CONNECT host:port` (HTTPS, tunnelled as is) and plain HTTP requests
  in absolute form (`GET http://host/path HTTP/1.1`), which it forwards with
  `Connection: close` so a client never sends a request for another host over the
  same connection. Anything else is refused. Refused hosts get `403 Forbidden` and
  are reported by `stop/1`, so the caller can tell a blocked download from other
  failures.

  Downloaders that ignore the proxy (yt-dlp's rtmpdump, mpv or aria2c support) are
  not installed in the image.

  The proxy connects to the targets directly; it does not chain to an outbound proxy
  configured through `HTTPS_PROXY` and the like, which yt-dlp would otherwise use.
  `start/1` logs a warning when one is set.

  The proxy belongs to the process that started it and stops when that process exits;
  its connections stop with it.
  """
  use GenServer

  alias Angler.Media.Egress
  alias Angler.Media.EgressProxy.Connection

  require Logger

  @enforce_keys [:pid, :url]
  defstruct [:pid, :url]

  @typedoc "A running proxy: its process and the URL to pass to `--proxy`."
  @type t :: %__MODULE__{pid: pid(), url: String.t()}

  @max_blocked 10
  @proxy_variables ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy)
  @proxy_warning_key {__MODULE__, :system_proxy_warning}

  @doc """
  Starts a proxy for the calling process on a free port of 127.0.0.1.

  Option `:check` replaces `Angler.Media.Egress.check/1`, the function that resolves
  and vets a host (tests use it to reach local servers).
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts \\ []) do
    check = Keyword.get(opts, :check, &Egress.check/1)
    warn_about_system_proxy()

    with {:ok, pid} <- GenServer.start(__MODULE__, {self(), check}) do
      {:ok, %__MODULE__{pid: pid, url: GenServer.call(pid, :url)}}
    end
  end

  # Logged once for every proxy configuration, naming only the variables (their
  # values may hold credentials).
  defp warn_about_system_proxy do
    configured = for name <- @proxy_variables, System.get_env(name) not in [nil, ""], do: name
    fingerprint = :erlang.phash2(Enum.map(configured, &{&1, System.get_env(&1)}))

    if configured != [] and :persistent_term.get(@proxy_warning_key, nil) != fingerprint do
      :persistent_term.put(@proxy_warning_key, fingerprint)

      Logger.warning(
        "Downloads ignore the proxy set in #{Enum.join(configured, ", ")}: yt-dlp goes " <>
          "through Angler's private network guard, which connects directly. Set " <>
          "ALLOW_PRIVATE_NETWORK_DOWNLOADS=true to download through the configured proxy " <>
          "(downloads may then reach private network addresses)"
      )
    end
  end

  @doc """
  Stops the proxy and returns the hosts it refused (in order, at most #{@max_blocked}).
  """
  @spec stop(t()) :: [String.t()]
  def stop(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :stop)
  catch
    :exit, _reason -> []
  end

  @impl true
  def init({owner, check}) do
    options = [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true, backlog: 128]

    case :gen_tcp.listen(0, options) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        proxy = self()
        spawn_link(fn -> accept(listen, proxy, check) end)

        {:ok,
         %{
           owner: Process.monitor(owner),
           listen: listen,
           url: "http://127.0.0.1:#{port}",
           blocked: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, state.url, state}
  def handle_call(:stop, _from, state), do: {:stop, :normal, Enum.reverse(state.blocked), state}

  @impl true
  def handle_info({:blocked, host}, state) do
    blocked =
      if host in state.blocked or length(state.blocked) >= @max_blocked,
        do: state.blocked,
        else: [host | state.blocked]

    {:noreply, %{state | blocked: blocked}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Connections monitor the proxy and stop when it does; closing the listening
  # socket (it belongs to this process) ends the acceptor.
  defp accept(listen, proxy, check) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        connection = spawn(fn -> Connection.serve(proxy, check) end)

        case :gen_tcp.controlling_process(socket, connection) do
          :ok -> send(connection, {:socket, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept(listen, proxy, check)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end
end
