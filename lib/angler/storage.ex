defmodule Angler.Storage do
  @moduledoc """
  Local media storage under `<data_dir>/media/<entry id>/` and enforcement of the
  dashboard's storage limits (see `enforce_limits/0`).

  Each entry's files live in its own directory; `entries.stored_bytes` mirrors how
  many bytes that directory holds so usage can be computed with a single query.
  The final artifacts use the names from `output_paths/1` (albums: the layout of
  `Angler.Storage.Album`); anything else in an entry directory is an intermediate
  (source download, 2-pass logs, partial files) and is deleted by `finalize/2`.

  Files of an entry that is not being processed are only deleted with the entry's
  row locked (`SELECT ... FOR UPDATE`) and read again: meanwhile the pipeline can't
  claim the entry (claims skip locked rows) and the dashboard can't re-queue or
  delete it, and a caller holding an outdated `%Entry{}` never deletes the
  directory of a newer attempt.

  All entry changes go through `Angler.Entries.update!/2` so the dashboard sees
  them; this module only runs (locking) reads on the `entries` table itself.
  """
  import Ecto.Query

  require Logger

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Repo
  alias Angler.Settings
  alias Angler.Storage.{Album, Cleanup, Disk, Janitor}

  @typedoc "What a cleanup run (`enforce_limits/0`) did."
  @type cleanup_result :: %{purged: non_neg_integer(), freed_bytes: non_neg_integer()}

  @mb 1_000_000

  @doc """
  Fixed file names inside an entry directory for the final artifacts, so the
  dashboard can find them later: `Angler.Media.prepare/3` must write the final video
  to `video` and the thumbnail to `thumbnail`.
  """
  @spec output_paths(Path.t()) :: %{video: Path.t(), thumbnail: Path.t()}
  def output_paths(dir),
    do: %{video: Path.join(dir, "video.mp4"), thumbnail: Path.join(dir, "thumbnail.jpg")}

  @doc "Root directory holding one sub-directory per entry."
  @spec root() :: Path.t()
  def root, do: Path.join(Application.fetch_env!(:angler, Angler.Media)[:data_dir], "media")

  @doc """
  Whether `path` lies strictly inside `root/0` (after `Path.expand/1`). Files are
  only deleted or served when this holds.
  """
  @spec managed_path?(Path.t()) :: boolean()
  def managed_path?(path) when is_binary(path) do
    String.starts_with?(Path.expand(path), Path.expand(root()) <> "/")
  end

  @doc """
  Creates the working directory of an entry, recording it as the entry's
  `storage_path`. A directory left over from a previous attempt is emptied first so
  every attempt starts clean.

  Downloads must leave enough free disk space for the database, which shares the
  disk in the default deployment. When free space is below the floor of
  `Angler.Storage.Disk.free_space_deficit/1`, a cleanup runs first (evicting kept
  videos, see `enforce_limits/0`); returns `{:error, :low_disk_space}` if that
  didn't free enough. Unknown free space never blocks a download.

  Returns `{:error, reason}` (e.g. `:enospc`, `:eacces`) when the directory can't be
  prepared.
  """
  @spec prepare_dir(Entry.t()) ::
          {:ok, Path.t(), Entry.t()} | {:error, :low_disk_space | File.posix()}
  def prepare_dir(%Entry{} = entry) do
    dir = Path.join(root(), entry.id)

    with {:ok, _removed} <- File.rm_rf(dir),
         :ok <- File.mkdir_p(dir),
         entry = Entries.update!(entry, %{storage_path: dir, stored_bytes: 0, purged_at: nil}),
         :ok <- ensure_free_space() do
      {:ok, dir, entry}
    else
      {:error, reason, _path} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Called after successful delivery: keeps only the files in `keep` (the final
  video and thumbnail, or an album's files, see `album_files/1`), deletes
  intermediates, updates `stored_bytes`, and purges right away when the
  retention period is 0. Leaves the files alone if the entry is being processed
  again already.

  `keep` holds absolute paths (`nil`s are ignored). Asks the `Angler.Storage.Janitor`
  for a run soon, so the size cap is enforced after new files are kept.
  """
  @spec finalize(Entry.t(), keep :: [Path.t() | nil]) :: Entry.t()
  def finalize(%Entry{} = entry, keep) do
    if Settings.get().retention_hours == 0 do
      purge(entry)
    else
      keep = keep |> Enum.reject(&is_nil/1) |> Enum.map(&Path.expand/1)

      entry =
        with_idle_entry(entry, fn idle ->
          prune_entry_dir(idle.storage_path, keep)
          record_usage(idle)
        end)

      Janitor.schedule_run()
      entry
    end
  end

  @doc """
  Recomputes and stores `stored_bytes` for an entry's directory (0 when it has
  none). Skips the write when the value did not change.
  """
  @spec record_usage(Entry.t()) :: Entry.t()
  def record_usage(%Entry{} = entry) do
    case Disk.tree_size(entry.storage_path) do
      bytes when bytes == entry.stored_bytes -> entry
      bytes -> Entries.update!(entry, %{stored_bytes: bytes})
    end
  end

  @doc """
  Deletes all files of an entry and marks it purged. Idempotent: an entry without
  files is returned unchanged.

  Works on the entry's current row, which is returned: an entry that is being
  processed (e.g. claimed again since the caller read it) keeps its files, and an
  entry deleted meanwhile is returned as given.

  Only directories inside `root/0` are ever deleted. When deleting fails, the
  error is logged and `stored_bytes` is updated to what is left.
  """
  @spec purge(Entry.t()) :: Entry.t()
  def purge(%Entry{} = entry), do: with_idle_entry(entry, &purge_files/1)

  @doc false
  # For `Angler.Storage.Cleanup`: purges the entry when `purge?` holds for its
  # current row, read with the row locked.
  @spec purge_if(Ecto.UUID.t(), (Entry.t() -> boolean())) ::
          {:purged, before :: Entry.t(), purged :: Entry.t()} | :skipped
  def purge_if(id, purge?) do
    locked(id, fn
      %Entry{} = entry ->
        if purge?.(entry), do: {:purged, entry, purge_files(entry)}, else: :skipped

      nil ->
        :skipped
    end)
  end

  @doc "Final video of a delivered entry, if still on disk."
  @spec video_path(Entry.t()) :: Path.t() | nil
  def video_path(%Entry{} = entry), do: existing_output(entry, :video)

  @doc "Thumbnail of a delivered entry, if still on disk."
  @spec thumbnail_path(Entry.t()) :: Path.t() | nil
  def thumbnail_path(%Entry{} = entry), do: existing_output(entry, :thumbnail)

  ## Albums

  @doc """
  The items of an album entry (`Angler.Entries.MediaItem`, in display order), each
  as `%{index: index, item: item, path: path, thumbnail_path: path}`: `index`
  counts from 0 and the paths are absolute, or nil unless the file is on disk and
  its stored path is valid (see `Angler.Storage.Album`).
  """
  @spec media_items(Entry.t()) :: [Album.item()]
  defdelegate media_items(entry), to: Album

  @doc """
  The file of the album item at `index` (from 0), if it is on disk and its stored
  path is valid (see `Angler.Storage.Album`); nil for any other index.
  """
  @spec media_item_path(Entry.t(), integer()) :: Path.t() | nil
  defdelegate media_item_path(entry, index), to: Album

  @doc "Like `media_item_path/2`, for the item's thumbnail (videos only)."
  @spec media_item_thumbnail_path(Entry.t(), integer()) :: Path.t() | nil
  defdelegate media_item_thumbnail_path(entry, index), to: Album

  @doc """
  The files an album entry keeps (`finalize/2`): its items' files and thumbnails
  and the cover thumbnail, as far as they are on disk and valid.
  """
  @spec album_files(Entry.t()) :: [Path.t()]
  defdelegate album_files(entry), to: Album

  @doc """
  Storage usage for the dashboard. `used_bytes` and `entries_with_files` cover the
  files kept by finished entries, which the storage limit applies to;
  `in_progress_bytes` is what queued and active entries hold. Disk values are nil
  when unknown.
  """
  @spec usage() :: %{
          used_bytes: non_neg_integer(),
          in_progress_bytes: non_neg_integer(),
          limit_bytes: pos_integer(),
          entries_with_files: non_neg_integer(),
          disk_total_bytes: non_neg_integer() | nil,
          disk_free_bytes: non_neg_integer() | nil
        }
  def usage do
    finished = Entry.terminal_statuses()

    counts =
      Repo.one(
        from e in Entry,
          select: %{
            used_bytes:
              type(coalesce(filter(sum(e.stored_bytes), e.status in ^finished), 0), :integer),
            in_progress_bytes:
              type(coalesce(filter(sum(e.stored_bytes), e.status not in ^finished), 0), :integer),
            entries_with_files: filter(count(e.id), e.stored_bytes > 0 and e.status in ^finished)
          }
      )

    {disk_total, disk_free} = Disk.space(root())

    Map.merge(counts, %{
      limit_bytes: Settings.storage_limit_bytes(Settings.get()),
      disk_total_bytes: disk_total,
      disk_free_bytes: disk_free
    })
  end

  @doc """
  Applies the storage limits to finished entries (done, failed or cancelled);
  never touches entries that are queued or in progress:

    * retention: purges the files of entries older than the retention period
    * size cap: purges the oldest entries until the files they keep fit the limit
    * free disk space: purges the oldest entries while the disk has less free
      space than the floor of `Angler.Storage.Disk.free_space_deficit/1`
    * history: deletes entries older than the history period, files first
      (`Angler.Entries.History`)

  It also reconciles the disk with the database: directories under `root/0` that
  no entry references (older than 10 minutes) are removed, and entries whose
  directory disappeared are marked purged. See `Angler.Storage.Cleanup`.

  Returns `%{purged: count, freed_bytes: bytes}`, where `freed_bytes` includes the
  size of removed orphan directories.
  """
  @spec enforce_limits() :: cleanup_result()
  defdelegate enforce_limits, to: Cleanup, as: :run

  ## Free disk space

  defp ensure_free_space do
    if Disk.free_space_deficit(root()) > 0 do
      Janitor.run_now()

      case Disk.free_space_deficit(root()) do
        0 ->
          :ok

        deficit ->
          Logger.warning(
            "Not enough free disk space to start a download: " <>
              "#{Float.round(deficit / @mb, 1)} MB more must be freed"
          )

          {:error, :low_disk_space}
      end
    else
      :ok
    end
  end

  ## Entry directories

  # Runs `fun` with the entry's current row while it is locked, unless the entry is
  # being processed (its current row is returned) or was deleted (`entry` is).
  defp with_idle_entry(%Entry{id: id} = entry, fun) do
    locked(id, fn
      nil -> entry
      %Entry{} = current -> if Entry.active?(current), do: current, else: fun.(current)
    end)
  end

  # Calls `fun` with the entry's row (nil if it doesn't exist) locked until `fun`
  # returns.
  defp locked(id, fun) do
    {:ok, result} =
      Repo.transact(fn ->
        {:ok, fun.(Repo.one(from e in Entry, where: e.id == ^id, lock: "FOR UPDATE"))}
      end)

    result
  end

  defp purge_files(%Entry{} = entry) do
    case remove_entry_dirs(entry) do
      {:ok, removed?} ->
        if removed? or holds_files?(entry), do: mark_purged(entry), else: entry

      {:error, reason, path} ->
        Logger.warning("Could not delete #{path}: #{:file.format_error(reason)}")
        record_usage(entry)
    end
  end

  defp holds_files?(%Entry{stored_bytes: bytes, storage_path: path}),
    do: bytes != 0 or not is_nil(path)

  defp mark_purged(%Entry{} = entry) do
    Entries.update!(entry, %{stored_bytes: 0, storage_path: nil, purged_at: DateTime.utc_now()})
  end

  defp existing_output(%Entry{storage_path: nil}, _kind), do: nil

  defp existing_output(%Entry{storage_path: dir}, kind) do
    path = Map.fetch!(output_paths(dir), kind)
    if File.regular?(path), do: path
  end

  defp prune_entry_dir(nil, _keep), do: :ok

  defp prune_entry_dir(dir, keep) do
    if managed_path?(dir) do
      prune(Path.expand(dir), keep)
    else
      Logger.warning("Not pruning #{dir}: outside of the storage root #{root()}")
    end
  end

  # Deletes everything under `dir` except the kept paths (and the directories
  # leading to them).
  defp prune(dir, keep) do
    case File.ls(dir) do
      {:ok, names} -> Enum.each(names, &prune_path(Path.join(dir, &1), keep))
      {:error, _reason} -> :ok
    end
  end

  defp prune_path(path, keep) do
    cond do
      path in keep -> :ok
      Enum.any?(keep, &String.starts_with?(&1, path <> "/")) -> prune(path, keep)
      true -> Disk.remove(path)
    end
  end

  # Removes the recorded directory and the canonical one (it may exist without
  # being recorded after a crash). Returns whether anything was deleted.
  defp remove_entry_dirs(%Entry{} = entry) do
    [entry.storage_path, Path.join(root(), entry.id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, false}, fn dir, {:ok, removed?} ->
      case remove_entry_dir(dir) do
        :ok -> {:cont, {:ok, true}}
        :skipped -> {:cont, {:ok, removed?}}
        {:error, _reason, _file} = error -> {:halt, error}
      end
    end)
  end

  defp remove_entry_dir(dir) do
    cond do
      not managed_path?(dir) ->
        Logger.warning("Not deleting #{dir}: outside of the storage root #{root()}")
        :skipped

      match?({:error, _}, File.lstat(dir)) ->
        :skipped

      true ->
        with {:ok, _removed} <- File.rm_rf(dir), do: :ok
    end
  end
end
