defmodule Angler.Media.Command do
  @moduledoc """
  Runs an external program with a hard time limit, streaming its output line by line.

  Closing an Erlang port does not stop the OS process behind it, so every command
  runs in a dedicated runner process that owns the port, records the OS pid and is
  linked to the caller. The runner stops the program (`SIGTERM`, then `SIGKILL` after
  a grace period) when the timeout expires or when the caller exits, and then waits
  for the port to close, so no program outlives its caller. The port reports the
  exit status only once the output pipe is closed, so a run also lasts as long as
  anything the program started keeps that pipe open; the timeout covers that too.

  Programs are started with `:spawn_executable` and an argument list: no shell is
  involved, so arguments (including user supplied URLs) are never interpreted. The
  runtime starts port programs in a new session (`setsid`), so signals are sent to
  the whole process group: helpers started by the tool (yt-dlp runs ffmpeg, and its
  PyInstaller bootloader runs a child Python process) are stopped as well.

  Standard error is merged into standard output. Lines are decoded leniently
  (invalid UTF-8 is replaced) because tool output ends up in the database.

  The tools parse untrusted pages and media (and yt-dlp may update itself from its
  nightly channel), so programs do not inherit the app's secrets: environment
  variables whose names look like credentials (`TELEGRAM_BOT_TOKEN`,
  `SECRET_KEY_BASE`, `DATABASE_URL`, `DASHBOARD_PASSWORD`, `RELEASE_COOKIE`, ...)
  are removed from their environment.
  """

  require Logger

  @line_length 16_384
  @max_line_bytes 65_536
  @default_max_lines 200
  @default_kill_grace 5_000
  @default_tick_interval 1_000

  @type result ::
          {:ok, %{exit_status: non_neg_integer(), output: [String.t()]}}
          | {:error, :timeout, [String.t()]}
          | {:error, {:port_exit, term()}, [String.t()]}
          | {:error, :enoent | :eacces | atom()}

  @doc """
  Runs `executable` with `args` and waits for it to exit.

  `executable` is a path or a bare name looked up in `PATH`.

  Options:

    * `:timeout` - milliseconds before the program is killed, or `:infinity` (default)
    * `:on_line` - called with every output line (without the line break). It runs
      in the runner process, so it must be cheap and must not rely on the caller's
      process dictionary. If it raises or throws, the program is killed and the
      exception (or thrown value) is raised again in the caller.
    * `:on_tick` - a zero-arity function called every `:tick_interval` milliseconds
      (default #{@default_tick_interval}) while the program runs, e.g. to watch what
      it writes even when it prints nothing. Same rules as `:on_line`.
    * `:cd` - working directory
    * `:env` - extra environment variables as `{name, value}` pairs (`nil` unsets);
      secrets are removed either way (see the module documentation)
    * `:max_lines` - how many of the last output lines to return (default #{@default_max_lines})
    * `:kill_grace` - milliseconds between `SIGTERM` and `SIGKILL` (default #{@default_kill_grace})

  Returns `{:ok, %{exit_status: status, output: lines}}` whatever the exit status
  (callers interpret it), `{:error, :timeout, lines}` when the program was killed
  because it took too long, or `{:error, :enoent}` when the executable does not exist
  (another POSIX error such as `:eacces` when it cannot be started).
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    with {:ok, path} <- find_executable(executable) do
      caller = self()
      ref = make_ref()
      runner = spawn_link(fn -> run_port(caller, ref, path, args, opts) end)
      monitor = Process.monitor(runner)
      await_runner(runner, monitor, ref)
    end
  end

  @doc """
  Resolves `executable` to an absolute path: names containing `/` are paths, bare
  names are looked up in `PATH`.
  """
  @spec find_executable(String.t()) :: {:ok, Path.t()} | {:error, :enoent}
  def find_executable(executable) do
    path =
      if String.contains?(executable, "/"),
        do: Path.expand(executable),
        else: System.find_executable(executable)

    if path && File.regular?(path), do: {:ok, path}, else: {:error, :enoent}
  end

  defp await_runner(runner, monitor, ref) do
    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(runner)

        # A caller that traps exits may already have the runner's exit message.
        receive do
          {:EXIT, ^runner, _reason} -> :ok
        after
          0 -> :ok
        end

        case reply do
          {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
          result -> result
        end

      {:DOWN, ^monitor, :process, ^runner, reason} ->
        exit(reason)
    end
  end

  ## Runner process

  defp run_port(caller, ref, path, args, opts) do
    Process.flag(:trap_exit, true)

    case open_port(path, args, opts) do
      {:ok, port} ->
        state = %{
          port: port,
          os_pid: os_pid(port),
          caller: caller,
          on_line: Keyword.get(opts, :on_line),
          on_tick: Keyword.get(opts, :on_tick),
          tick_interval: Keyword.get(opts, :tick_interval, @default_tick_interval),
          kill_grace: Keyword.get(opts, :kill_grace, @default_kill_grace),
          max_lines: Keyword.get(opts, :max_lines, @default_max_lines),
          lines: :queue.new(),
          line_count: 0,
          partial: [],
          partial_size: 0,
          exit_status: nil,
          stopping: nil,
          raised: nil
        }

        case Keyword.get(opts, :timeout, :infinity) do
          :infinity -> :ok
          timeout when is_integer(timeout) -> Process.send_after(self(), :timeout, timeout)
        end

        send(caller, {ref, state |> schedule_tick() |> loop()})

      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
    end
  end

  defp open_port(path, args, opts) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, {:line, @line_length}, args: args] ++
        if(opts[:cd], do: [cd: opts[:cd]], else: []) ++ [env: port_env(opts[:env] || [])]

    {:ok, Port.open({:spawn_executable, path}, port_opts)}
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp port_env(env) do
    secrets =
      for {name, _value} <- System.get_env(),
          name =~ ~r/TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|API_HASH|DATABASE_URL/i,
          not List.keymember?(env, name, 0),
          do: {name, nil}

    Enum.map(secrets ++ env, fn
      {name, nil} -> {to_charlist(name), false}
      {name, value} -> {to_charlist(name), to_charlist(value)}
    end)
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # The port reports the exit status at EOF of the output pipe, but a trailing line
  # without a line break arrives after it: the run is complete when the port closes.
  defp loop(%{port: port, caller: caller} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        state |> append_partial(chunk) |> complete_line() |> loop()

      {^port, {:data, {:noeol, chunk}}} ->
        state |> append_partial(chunk) |> loop()

      {^port, {:exit_status, status}} ->
        loop(%{state | exit_status: status})

      {:EXIT, ^port, reason} ->
        finish(state, reason)

      {:EXIT, ^caller, _reason} ->
        loop(stop(state, :caller_exited))

      :timeout ->
        loop(stop(state, :timeout))

      :tick ->
        state |> tick() |> loop()

      :kill ->
        signal(state, "KILL")
        Process.send_after(self(), :close, state.kill_grace)
        loop(state)

      :close ->
        Logger.error("OS process #{state.os_pid} or its children did not exit after SIGKILL")
        close_port(port)
        finish(state, :closed)
    end
  end

  defp stop(%{stopping: stopping} = state, _reason) when not is_nil(stopping), do: state
  defp stop(%{exit_status: status} = state, :timeout) when not is_nil(status), do: state

  defp stop(state, reason) do
    signal(state, "TERM")
    Process.send_after(self(), :kill, state.kill_grace)
    %{state | stopping: reason}
  end

  defp finish(state, port_exit_reason) do
    state = complete_line(state)
    output = :queue.to_list(state.lines)

    cond do
      state.raised ->
        {kind, reason, stacktrace} = state.raised
        {:raise, kind, reason, stacktrace}

      state.stopping == :timeout ->
        {:error, :timeout, output}

      state.stopping == :caller_exited ->
        :caller_exited

      state.exit_status ->
        {:ok, %{exit_status: state.exit_status, output: output}}

      true ->
        signal(state, "KILL")
        {:error, {:port_exit, port_exit_reason}, output}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  ## Output lines

  defp append_partial(%{partial_size: size} = state, _chunk) when size >= @max_line_bytes,
    do: state

  defp append_partial(state, chunk) do
    %{
      state
      | partial: [state.partial | chunk],
        partial_size: state.partial_size + byte_size(chunk)
    }
  end

  defp complete_line(%{partial: [], partial_size: 0} = state), do: state

  defp complete_line(state) do
    line =
      state.partial
      |> IO.iodata_to_binary()
      |> String.replace_invalid()
      |> String.trim_trailing("\r")

    state = %{keep_line(state, line) | partial: [], partial_size: 0}
    notify(state, line)
  end

  defp keep_line(%{line_count: count, max_lines: max} = state, line) when count >= max do
    {_, lines} = :queue.out(state.lines)
    %{state | lines: :queue.in(line, lines)}
  end

  defp keep_line(state, line) do
    %{state | lines: :queue.in(line, state.lines), line_count: state.line_count + 1}
  end

  # Callbacks only run while the program is running normally.
  defp notify(%{on_line: on_line, stopping: nil} = state, line) when is_function(on_line, 1),
    do: callback(state, fn -> on_line.(line) end)

  defp notify(state, _line), do: state

  defp tick(%{on_tick: on_tick, stopping: nil, exit_status: nil} = state)
       when is_function(on_tick, 0),
       do: state |> callback(on_tick) |> schedule_tick()

  defp tick(state), do: state

  defp schedule_tick(%{on_tick: on_tick, stopping: nil} = state) when is_function(on_tick, 0) do
    Process.send_after(self(), :tick, state.tick_interval)
    state
  end

  defp schedule_tick(state), do: state

  defp callback(state, fun) do
    fun.()
    state
  catch
    kind, reason -> stop(%{state | raised: {kind, reason, __STACKTRACE__}}, :raised)
  end

  # Signals the program's process group and, while it has not exited, the program
  # itself (in case it is not a group leader). Once the port reported the exit status
  # its pid may be reused, so only the group is signalled. Debian slim images ship no
  # kill(1) binary, so this uses the shell builtin with positional parameters.
  defp signal(%{os_pid: nil}, _signal), do: :ok

  defp signal(%{os_pid: os_pid, exit_status: status}, signal) do
    pid = Integer.to_string(os_pid)
    targets = if is_nil(status), do: ["-" <> pid, pid], else: ["-" <> pid]

    System.cmd(
      "/bin/sh",
      ["-c", ~s(sig=$1; shift; kill -s "$sig" -- "$@" 2>/dev/null), "kill", signal | targets],
      stderr_to_stdout: true
    )

    :ok
  end
end
