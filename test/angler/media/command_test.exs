defmodule Angler.Media.CommandTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Command

  @moduletag :tmp_dir

  defp script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp alive?(os_pid) do
    # Zombies (exited, not yet reaped by init) count as dead.
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_, _} -> false
    end
  end

  defp kill_0(os_pid) do
    {_, status} =
      System.cmd("/bin/sh", ["-c", ~s(kill -0 "$1" 2>/dev/null), "sh", to_string(os_pid)])

    status
  end

  # Orphaned grandchildren are reaped asynchronously by init.
  defp eventually_dead?(os_pid, attempts \\ 100) do
    cond do
      not alive?(os_pid) -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually_dead?(os_pid, attempts - 1)
    end
  end

  test "returns the exit status and the output lines", %{tmp_dir: dir} do
    path = script(dir, "ok.sh", "echo one\necho two >&2\nprintf 'three'\nexit 3\n")

    assert {:ok, %{exit_status: 3, output: ["one", "two", "three"]}} = Command.run(path, [])
  end

  test "streams complete lines to :on_line", %{tmp_dir: dir} do
    path = script(dir, "lines.sh", "echo first\necho\nprintf 'last'\n")
    test = self()

    assert {:ok, %{exit_status: 0}} = Command.run(path, [], on_line: &send(test, {:line, &1}))
    assert_received {:line, "first"}
    assert_received {:line, ""}
    assert_received {:line, "last"}
  end

  test "joins lines longer than the port line buffer", %{tmp_dir: dir} do
    path = script(dir, "long.sh", "head -c 40000 /dev/zero | tr '\\0' x\necho\necho end\n")

    assert {:ok, %{output: [long, "end"]}} = Command.run(path, [])
    assert long == String.duplicate("x", 40_000)
  end

  test "keeps only the last :max_lines lines", %{tmp_dir: dir} do
    path = script(dir, "many.sh", "i=1; while [ $i -le 500 ]; do echo $i; i=$((i+1)); done\n")

    assert {:ok, %{output: output}} = Command.run(path, [])
    assert length(output) == 200
    assert List.first(output) == "301"
    assert List.last(output) == "500"

    assert {:ok, %{output: ["499", "500"]}} = Command.run(path, [], max_lines: 2)
  end

  test "passes arguments verbatim, without a shell", %{tmp_dir: dir} do
    path = script(dir, "args.sh", ~s(for a in "$@"; do echo "[$a]"; done\n))
    args = ["--", "https://example.com/?a=1&b=$(touch pwned)", "two words", "*"]

    assert {:ok, %{output: output}} = Command.run(path, args, cd: dir)
    assert output == Enum.map(args, &"[#{&1}]")
    refute File.exists?(Path.join(dir, "pwned"))
  end

  test "sets the working directory and environment", %{tmp_dir: dir} do
    path = script(dir, "env.sh", ~s(pwd -P\necho "$ANGLER_TEST_VAR"\n))

    assert {:ok, %{output: [cwd, "hello"]}} =
             Command.run(path, [], cd: dir, env: [{"ANGLER_TEST_VAR", "hello"}])

    assert cwd == Path.expand(dir) |> resolve_symlinks()
  end

  test "does not pass the app's secrets on", %{tmp_dir: dir} do
    names = ~w(ANGLER_TEST_BOT_TOKEN ANGLER_TEST_DB_PASSWORD ANGLER_TEST_DATABASE_URL
               ANGLER_TEST_RELEASE_COOKIE ANGLER_TEST_SECRET_KEY_BASE ANGLER_TEST_PLAIN)

    for name <- names, do: System.put_env(name, "value")
    on_exit(fn -> Enum.each(names, &System.delete_env/1) end)

    script = Enum.map_join(names, "\n", &~s(echo "#{&1}=${#{&1}-unset}"))
    path = script(dir, "secrets.sh", script <> "\n")

    assert {:ok, %{output: output}} = Command.run(path, [])

    assert output == [
             "ANGLER_TEST_BOT_TOKEN=unset",
             "ANGLER_TEST_DB_PASSWORD=unset",
             "ANGLER_TEST_DATABASE_URL=unset",
             "ANGLER_TEST_RELEASE_COOKIE=unset",
             "ANGLER_TEST_SECRET_KEY_BASE=unset",
             "ANGLER_TEST_PLAIN=value"
           ]

    assert {:ok, %{output: ["ANGLER_TEST_BOT_TOKEN=given" | _]}} =
             Command.run(path, [], env: [{"ANGLER_TEST_BOT_TOKEN", "given"}])
  end

  test "finds bare names on PATH" do
    assert {:ok, %{exit_status: 0, output: ["hi"]}} = Command.run("echo", ["hi"])
  end

  test "returns :enoent for missing executables", %{tmp_dir: dir} do
    assert {:error, :enoent} = Command.run("angler-no-such-tool", [])
    assert {:error, :enoent} = Command.run(Path.join(dir, "missing"), [])
  end

  test "returns the POSIX error when the file is not executable", %{tmp_dir: dir} do
    path = Path.join(dir, "plain.txt")
    File.write!(path, "echo hi\n")

    assert {:error, :eacces} = Command.run(path, [])
  end

  test "replaces invalid UTF-8 in output", %{tmp_dir: dir} do
    path = script(dir, "bytes.sh", "printf 'a\\377b\\n'\n")

    assert {:ok, %{output: ["a�b"]}} = Command.run(path, [])
  end

  # Timing-sensitive tests run /bin/sh -c: a freshly written script may be scanned by
  # the OS on its first run, delaying its start past short timeouts.
  defp sh(script, opts), do: Command.run("/bin/sh", ["-c", script], opts)

  test "kills the program and its children on timeout" do
    assert {:error, :timeout, [pids]} = sh("sleep 60 & echo $$ $!; wait", timeout: 1_000)

    [shell, child] = String.split(pids)
    assert kill_0(shell) != 0
    assert eventually_dead?(child)
  end

  test "escalates to SIGKILL when SIGTERM is ignored" do
    script = "trap '' TERM; echo $$; while :; do sleep 1; done"

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout, [pid]} = sh(script, timeout: 1_000, kill_grace: 300)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert kill_0(pid) != 0
  end

  test "kills children that keep the output open after the program exited" do
    assert {:error, :timeout, [child]} = sh("sleep 60 & echo $!", timeout: 1_000)
    assert eventually_dead?(child)
  end

  test "kills the program when the caller exits" do
    test = self()

    caller =
      spawn(fn ->
        sh("echo $$; exec sleep 60", on_line: fn line -> send(test, {:started, self(), line}) end)
      end)

    assert_receive {:started, runner, pid}, 5_000
    ref = Process.monitor(runner)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 10_000
    assert kill_0(pid) != 0
  end

  test "re-raises exceptions from :on_line in the caller and stops the program" do
    test = self()

    assert_raise RuntimeError, "boom", fn ->
      sh("echo $$; exec sleep 60",
        on_line: fn line ->
          send(test, {:pid, line})
          raise "boom"
        end
      )
    end

    assert_received {:pid, pid}
    assert kill_0(pid) != 0
  end

  test "calls :on_tick periodically while the program runs, even when it prints nothing" do
    test = self()

    assert {:ok, %{exit_status: 0, output: []}} =
             sh("sleep 1", on_tick: fn -> send(test, :tick) end, tick_interval: 100)

    assert_received :tick
    assert_received :tick
  end

  test "stops the program when :on_tick throws and throws again in the caller", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")
    on_tick = fn -> if File.exists?(pid_file), do: throw(:stop) end
    script = ~s(echo $$ > "$1.tmp" && mv "$1.tmp" "$1"; exec sleep 60)

    started = System.monotonic_time(:millisecond)

    assert catch_throw(
             Command.run("/bin/sh", ["-c", script, "sh", pid_file],
               on_tick: on_tick,
               tick_interval: 100
             )
           ) == :stop

    assert System.monotonic_time(:millisecond) - started < 20_000
    assert kill_0(pid_file |> File.read!() |> String.trim()) != 0
  end

  test "leaves no exit message behind for callers that trap exits", %{tmp_dir: dir} do
    path = script(dir, "quick.sh", "echo ok\n")

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        parent = self()
        {:ok, _} = Command.run(path, [], on_line: fn _ -> send(parent, {:runner, self()}) end)
        assert_received {:runner, runner}
        ref = Process.monitor(runner)
        assert_receive {:DOWN, ^ref, :process, ^runner, _}
        Process.info(self(), :messages)
      end)

    assert {:messages, []} = Task.await(task)
  end

  defp resolve_symlinks(path) do
    {resolved, 0} = System.cmd("/bin/sh", ["-c", ~s(cd "$1" && pwd -P), "sh", path])
    String.trim(resolved)
  end
end
