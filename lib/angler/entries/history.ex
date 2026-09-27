defmodule Angler.Entries.History do
  @moduledoc """
  Keeps the `entries` table from growing forever: deletes finished entries (done,
  failed or cancelled) long after they finished, as set by the `history_days`
  setting (`Angler.Settings.Setting`).

  `Angler.Storage.enforce_limits/0` (the storage janitor) purges the files of those
  entries first and then calls `prune/2`, which skips entries that still hold
  files. Deletions are broadcast like `Angler.Entries.delete/1` does.
  """
  import Ecto.Query

  alias Angler.Entries.Entry
  alias Angler.Repo

  @batch_size 1_000

  @doc """
  Deletes the finished entries that finished before `cutoff` and hold no files,
  in batches (option `:batch_size`, default #{@batch_size}), broadcasting
  `{:entry_deleted, id}` for each. Returns how many were deleted.
  """
  @spec prune(DateTime.t(), keyword()) :: non_neg_integer()
  def prune(%DateTime{} = cutoff, opts \\ []) do
    prune_batches(cutoff, Keyword.get(opts, :batch_size, @batch_size), 0)
  end

  defp prune_batches(cutoff, batch_size, deleted) do
    batch = from e in prunable(cutoff), select: e.id, limit: ^batch_size

    # The conditions are repeated outside of the subquery, so they are checked
    # again on rows changed meanwhile (e.g. re-queued from the dashboard).
    {count, ids} =
      Repo.delete_all(from e in prunable(cutoff), where: e.id in subquery(batch), select: e.id)

    Enum.each(ids, &Phoenix.PubSub.broadcast(Angler.PubSub, "entries", {:entry_deleted, &1}))

    if count == batch_size,
      do: prune_batches(cutoff, batch_size, deleted + count),
      else: deleted + count
  end

  defp prunable(cutoff) do
    from e in Entry,
      where: e.status in ^Entry.terminal_statuses() and e.finished_at < ^cutoff,
      where: e.stored_bytes == 0 and is_nil(e.storage_path)
  end
end
