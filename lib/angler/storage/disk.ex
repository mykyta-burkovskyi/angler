defmodule Angler.Storage.Disk do
  @moduledoc """
  Filesystem helpers for `Angler.Storage`: sizes of directory trees, deleting them,
  and the space of the filesystem holding the media (from `df`).

  The media shares its disk with the database in the default deployment, so
  `free_space_deficit/1` defines a floor that free space should not drop below:
  max(2 GB, 5% of the filesystem). Settings under `config :angler, Angler.Storage`:

    * `:min_free_bytes` - the absolute part of the floor (default 2 GB)
    * `:min_free_percent` - the relative part of the floor (default 5)
    * `:df_timeout` - milliseconds before a hanging `df` (e.g. on a stale network
      mount) is killed and the space is reported as unknown (default 5 seconds)
  """
  require Logger

  alias Angler.Media.Command

  @min_free_bytes 2_000_000_000
  @min_free_percent 5
  @df_timeout :timer.seconds(5)
  @df_kill_grace 1_000

  @doc "Bytes held by a file or directory tree (0 if it doesn't exist). Symlinks are not followed."
  @spec tree_size(Path.t() | nil) :: non_neg_integer()
  def tree_size(nil), do: 0

  def tree_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> Enum.sum_by(names, &tree_size(Path.join(path, &1)))
          {:error, _reason} -> 0
        end

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _reason} ->
        0
    end
  end

  @doc "Deletes a file or directory tree, logging failures."
  @spec remove(Path.t()) :: :ok | :error
  def remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, file} ->
        Logger.warning("Could not delete #{file}: #{:file.format_error(reason)}")
        :error
    end
  end

  @doc """
  Total and free bytes of the filesystem holding `path` (or its nearest existing
  ancestor). `{nil, nil}` when unknown: `df` is missing, fails or hangs.
  """
  @spec space(Path.t()) :: {non_neg_integer(), non_neg_integer()} | {nil, nil}
  def space(path) do
    args = ["-Pk", existing_ancestor(Path.expand(path))]

    # Command kills the program when it hangs (without needing a kill(1) binary).
    case Command.run("df", args, timeout: config(:df_timeout), kill_grace: @df_kill_grace) do
      {:ok, %{exit_status: 0, output: lines}} -> parse_df(lines)
      _error -> {nil, nil}
    end
  end

  @doc """
  How many bytes must be freed for the filesystem holding `path` to have at least
  max(`:min_free_bytes`, `:min_free_percent` of its size) free. 0 when there is
  enough free space or when it is unknown.
  """
  @spec free_space_deficit(Path.t()) :: non_neg_integer()
  def free_space_deficit(path) do
    case space(path) do
      {nil, nil} ->
        0

      {total, free} ->
        min_free = max(config(:min_free_bytes), div(total * config(:min_free_percent), 100))
        max(min_free - free, 0)
    end
  end

  defp existing_ancestor(path) do
    parent = Path.dirname(path)
    if File.dir?(path) or parent == path, do: path, else: existing_ancestor(parent)
  end

  # POSIX output: a header line, then
  # "<filesystem> <1024-blocks> <used> <available> <capacity>% <mounted on>".
  # Matching the numbers tolerates spaces in the filesystem name and mount point.
  defp parse_df([_header, line | _rest]) do
    case Regex.run(~r/\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s/, line <> " ") do
      [_match, total, _used, free] ->
        {String.to_integer(total) * 1024, String.to_integer(free) * 1024}

      nil ->
        {nil, nil}
    end
  end

  defp parse_df(_lines), do: {nil, nil}

  defp config(key) do
    defaults = [
      min_free_bytes: @min_free_bytes,
      min_free_percent: @min_free_percent,
      df_timeout: @df_timeout
    ]

    :angler
    |> Application.get_env(Angler.Storage, [])
    |> Keyword.get(key, defaults[key])
  end
end
