defmodule Angler.Storage.Cleanup do
  @moduledoc """
  A storage cleanup run (`Angler.Storage.enforce_limits/0`, run by
  `Angler.Storage.Janitor`). In order:

    1. Retention: purges the files of finished entries older than the retention
       period, or than the history period when that is shorter (entries don't
       outlive their files).
    2. Reconciliation: removes directories under the storage root that no entry
       records (older than 10 minutes), and marks entries whose directory
       disappeared as purged, so the next steps work with accurate numbers.
    3. Size cap: purges the oldest finished entries until the files kept by
       finished entries fit the storage limit. Work in progress doesn't count.
    4. Free disk space: purges the oldest finished entries while the disk has
       less free space than `Angler.Storage.Disk.free_space_deficit/1` wants.
    5. History: deletes finished entries older than the history period
       (`Angler.Entries.History`).

  Only finished entries (done, failed or cancelled) are touched, and each purge
  checks that again with the entry's row locked (`Angler.Storage.purge_if/2`).
  """
  import Ecto.Query

  require Logger

  alias Angler.Entries.{Entry, History}
  alias Angler.{Repo, Settings, Storage}
  alias Angler.Settings.Setting
  alias Angler.Storage.Disk

  # Directories this young may belong to a claim that has not recorded its
  # `storage_path` yet, so the orphan sweep leaves them alone.
  @orphan_grace_seconds 600
  @mb 1_000_000

  @doc "Runs a cleanup, see the moduledoc and `Angler.Storage.enforce_limits/0`."
  @spec run() :: Storage.cleanup_result()
  def run do
    settings = Settings.get()

    stats =
      %{purged: 0, freed_bytes: 0, orphans: 0, deleted: 0}
      |> purge_expired(settings)
      |> reconcile()
      |> enforce_cap(Settings.storage_limit_bytes(settings))
      |> enforce_free_space()
      |> prune_history(settings)

    if stats.purged > 0 or stats.orphans > 0 or stats.deleted > 0 do
      Logger.info(
        "Storage cleanup: purged files of #{stats.purged} entries, " <>
          "removed #{stats.orphans} orphaned directories, freed #{format_mb(stats.freed_bytes)}, " <>
          "deleted #{stats.deleted} old entries"
      )
    end

    Map.take(stats, [:purged, :freed_bytes])
  end

  ## Retention and history

  defp purge_expired(stats, %Setting{} = settings) do
    query =
      from e in Entry,
        where: e.status in ^Entry.terminal_statuses(),
        where: e.stored_bytes > 0 or not is_nil(e.storage_path),
        select: e.id

    query =
      case expiry_cutoff(settings) do
        nil -> query
        cutoff -> where(query, [e], e.finished_at < ^cutoff)
      end

    query
    |> Repo.all()
    |> Enum.reduce(stats, &add_purge(&2, purge_finished(&1)))
  end

  # nil: files are not kept at all.
  defp expiry_cutoff(%Setting{retention_hours: 0}), do: nil

  defp expiry_cutoff(%Setting{retention_hours: hours} = settings) do
    retention = DateTime.add(DateTime.utc_now(), -hours, :hour)

    case history_cutoff(settings) do
      nil -> retention
      history -> Enum.max([retention, history], DateTime)
    end
  end

  # nil: entries are kept forever.
  defp history_cutoff(%Setting{history_days: 0}), do: nil

  defp history_cutoff(%Setting{history_days: days}),
    do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp prune_history(stats, %Setting{} = settings) do
    case history_cutoff(settings) do
      nil -> stats
      cutoff -> %{stats | deleted: History.prune(cutoff)}
    end
  end

  ## Size cap and free disk space

  defp enforce_cap(stats, limit), do: evict_oldest(stats, kept_bytes() - limit)

  defp enforce_free_space(stats) do
    case Disk.free_space_deficit(Storage.root()) do
      0 ->
        stats

      deficit ->
        after_eviction = evict_oldest(stats, deficit)
        missing = deficit - (after_eviction.freed_bytes - stats.freed_bytes)

        if missing > 0 do
          Logger.warning(
            "Low free disk space: #{format_mb(missing)} more should be freed, " <>
              "but no kept videos are left to delete"
          )
        end

        after_eviction
    end
  end

  # Purges the oldest finished entries holding files until `excess` bytes are freed.
  defp evict_oldest(stats, excess) when excess <= 0, do: stats

  defp evict_oldest(stats, excess) do
    ids =
      Repo.all(
        from e in Entry,
          where: e.status in ^Entry.terminal_statuses() and e.stored_bytes > 0,
          order_by: [asc_nulls_first: e.finished_at, asc: e.id],
          select: e.id
      )

    {_excess, stats} =
      Enum.reduce_while(ids, {excess, stats}, fn id, {excess, stats} ->
        if excess <= 0 do
          {:halt, {excess, stats}}
        else
          {_count, freed} = result = purge_finished(id)
          {:cont, {excess - freed, add_purge(stats, result)}}
        end
      end)

    stats
  end

  defp kept_bytes do
    Repo.one(
      from e in Entry,
        where: e.status in ^Entry.terminal_statuses(),
        select: type(coalesce(sum(e.stored_bytes), 0), :integer)
    )
  end

  # Purges an entry chosen from a (possibly stale) query result if it is still
  # finished, e.g. not re-queued from the dashboard in the meantime.
  # Returns `{purged_count, freed_bytes}`.
  defp purge_finished(id) do
    case Storage.purge_if(id, &Entry.terminal?/1) do
      {:purged, before, purged} ->
        count = if is_nil(purged.storage_path), do: 1, else: 0
        {count, max(before.stored_bytes - purged.stored_bytes, 0)}

      :skipped ->
        {0, 0}
    end
  end

  defp add_purge(stats, {count, freed}) do
    %{stats | purged: stats.purged + count, freed_bytes: stats.freed_bytes + freed}
  end

  ## Reconciling the disk with the database

  defp reconcile(stats) do
    recorded =
      Repo.all(
        from e in Entry,
          where: not is_nil(e.storage_path),
          select: {e.id, e.storage_path, e.status}
      )

    Enum.each(recorded, &forget_missing_dir/1)

    remove_orphans(
      stats,
      MapSet.new(recorded, fn {id, path, _status} -> {id, Path.expand(path)} end)
    )
  end

  # The directory of an entry that is not being worked on vanished (deleted by
  # hand, or the data dir changed): stop accounting for it.
  defp forget_missing_dir({id, path, status}) do
    if status not in Entry.active_statuses() and not File.dir?(path) do
      # Checked again: a worker may have claimed the entry since the query ran.
      Storage.purge_if(id, &(&1.storage_path == path and not Entry.active?(&1)))
    end
  end

  # Removes directories under the root whose name is not the id of an entry that
  # records it as its `storage_path` (left behind by crashes or deleted entries).
  defp remove_orphans(stats, recorded) do
    root = Path.expand(Storage.root())
    cutoff = System.os_time(:second) - @orphan_grace_seconds

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.map(&{&1, Path.join(root, &1)})
        |> Enum.reject(fn {name, dir} -> MapSet.member?(recorded, {name, dir}) end)
        |> Enum.filter(fn {_name, dir} -> stale_dir?(dir, cutoff) end)
        |> Enum.reduce(stats, fn {_name, dir}, stats -> remove_orphan(stats, dir) end)

      {:error, _reason} ->
        stats
    end
  end

  defp stale_dir?(dir, cutoff) do
    match?(
      {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff,
      File.lstat(dir, time: :posix)
    )
  end

  defp remove_orphan(stats, dir) do
    size = Disk.tree_size(dir)

    case Disk.remove(dir) do
      :ok -> %{stats | orphans: stats.orphans + 1, freed_bytes: stats.freed_bytes + size}
      :error -> stats
    end
  end

  defp format_mb(bytes), do: "#{Float.round(bytes / @mb, 1)} MB"
end
