defmodule AnglerWeb.EntryActions do
  @moduledoc """
  The dashboard's actions on an entry, shared by the entries list and the entry
  page. Each returns `{:ok, entry}` or `{:error, message}` with a message for the
  user, and should be given the entry as it is now (see `run/2`): the page may show
  an older state.
  """
  alias Angler.{Entries, Storage}
  alias Angler.Entries.Entry

  @type result :: {:ok, Entry.t()} | {:error, String.t()}

  @doc "Runs `action` on the current state of the entry with `id`."
  @spec run(String.t(), (Entry.t() -> result())) :: result()
  def run(id, action) do
    case Entries.get(id) do
      %Entry{} = entry -> action.(entry)
      nil -> {:error, "This entry no longer exists."}
    end
  end

  @spec retry(Entry.t()) :: result()
  def retry(%Entry{} = entry) do
    with {:error, :not_retryable} <- Entries.retry(entry),
         do: {:error, "Only finished entries can be retried."}
  end

  @spec cancel(Entry.t()) :: result()
  def cancel(%Entry{} = entry) do
    with {:error, :not_cancellable} <- Entries.cancel(entry),
         do: {:error, "Only queued entries can be cancelled."}
  end

  @doc """
  Deletes the stored files of a finished entry. Not of a queued one either: a
  worker claiming it would recreate its directory while it's being deleted.
  """
  @spec purge_files(Entry.t()) :: result()
  def purge_files(%Entry{} = entry) do
    # `Storage.purge/1` leaves an entry that became active meanwhile alone.
    with true <- Entry.terminal?(entry),
         %Entry{} = purged <- Storage.purge(entry),
         false <- Entry.active?(purged) do
      {:ok, purged}
    else
      _busy -> {:error, "Files can't be deleted while the entry is queued or being processed."}
    end
  end

  @doc """
  Deletes an entry and its files. A queued entry is cancelled first, so the
  pipeline can't claim it while its files are removed.
  """
  @spec delete(Entry.t()) :: result()
  def delete(%Entry{status: :queued} = entry) do
    case Entries.cancel(entry) do
      {:ok, cancelled} -> delete(cancelled)
      {:error, :not_cancellable} -> active_error()
    end
  end

  def delete(%Entry{} = entry) do
    if Entry.active?(entry) do
      active_error()
    else
      with {:error, :active} <- entry |> Storage.purge() |> Entries.delete(), do: active_error()
    end
  end

  defp active_error, do: {:error, "Entries can't be deleted while they're being processed."}
end
