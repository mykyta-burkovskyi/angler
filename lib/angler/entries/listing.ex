defmodule Angler.Entries.Listing do
  @moduledoc """
  Read-only queries behind the dashboard: the filtered, paginated list of entries
  and the numbers in its header. Used through `Angler.Entries`.
  """
  import Ecto.Query

  alias Angler.Entries.Entry
  alias Angler.Repo

  @typedoc "The dashboard header numbers, see `Angler.Entries.stats/0`."
  @type stats :: %{
          total: non_neg_integer(),
          delivered_24h: non_neg_integer(),
          failed_24h: non_neg_integer(),
          by_status: %{Entry.status() => non_neg_integer()}
        }

  @doc "See `Angler.Entries.list/1`."
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Entry
    |> filter_status(Keyword.get(opts, :filter, :all))
    |> filter_search(Keyword.get(opts, :search))
    |> filter_before(Keyword.get(opts, :before))
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_status(query, :all), do: query

  defp filter_status(query, :active),
    do: where(query, [e], e.status in ^[:queued | Entry.active_statuses()])

  defp filter_status(query, status) when is_atom(status),
    do: where(query, [e], e.status == ^status)

  defp filter_search(query, search) when search in [nil, ""], do: query

  defp filter_search(query, search) do
    pattern = "%" <> String.replace(search, ~w(\\ % _), &"\\#{&1}") <> "%"

    where(
      query,
      [e],
      ilike(e.url, ^pattern) or ilike(e.title, ^pattern) or ilike(e.chat_title, ^pattern) or
        ilike(e.from_name, ^pattern)
    )
  end

  defp filter_before(query, nil), do: query

  defp filter_before(query, %Entry{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [e],
      e.inserted_at < ^inserted_at or (e.inserted_at == ^inserted_at and e.id < ^id)
    )
  end

  @doc "See `Angler.Entries.count_by_status/0`."
  @spec count_by_status() :: %{Entry.status() => non_neg_integer()}
  def count_by_status do
    counts =
      Repo.all(from e in Entry, group_by: e.status, select: {e.status, count(e.id)})
      |> Map.new()

    Map.new(Entry.statuses(), &{&1, Map.get(counts, &1, 0)})
  end

  @doc "See `Angler.Entries.stats/0`."
  @spec stats() :: stats()
  def stats do
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    Repo.one(
      from e in Entry,
        select: %{
          total: count(e.id),
          delivered_24h: filter(count(e.id), e.status == :done and e.finished_at >= ^since),
          failed_24h: filter(count(e.id), e.status == :failed and e.finished_at >= ^since)
        }
    )
    |> Map.put(:by_status, count_by_status())
  end
end
