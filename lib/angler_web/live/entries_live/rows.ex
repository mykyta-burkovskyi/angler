defmodule AnglerWeb.EntriesLive.Rows do
  @moduledoc """
  The rows of the entries list (`AnglerWeb.EntriesLive`): paging, and placing
  real-time updates.

  The list is a stream, so the server keeps no entries. To place real-time updates
  correctly it only tracks the sort keys (`{inserted_at, id}`) of the rows the client
  shows, newest first (`@rows`). With them, a changed entry is inserted at its
  position, updated in place, or removed when it stops matching the filter; the
  client list stays bounded; and the next page starts right after the last row
  shown. Entries being processed are kept in `@active`, so progress broadcasts can
  re-render their row without querying the database.

  Every function takes and returns the socket: it reads the `:filter` and `:search`
  assigns, and maintains the `:entries` stream and the `:rows`, `:active`,
  `:progress` and `:end_of_list?` assigns.
  """
  import Phoenix.Component, only: [assign: 2, update: 3]

  import Phoenix.LiveView,
    only: [stream: 3, stream: 4, stream_insert: 3, stream_insert: 4, stream_delete_by_dom_id: 3]

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Phoenix.LiveView.Socket

  @per_page 50
  # Most rows kept on the client while new entries arrive at the top (unless the
  # user scrolled further; then that many).
  @max_rows 500

  @doc "Starts the list over with the first page of entries matching the filter and search."
  @spec reset(Socket.t()) :: Socket.t()
  def reset(socket) do
    socket
    |> assign(rows: [], active: %{})
    |> stream(:entries, [], reset: true)
    |> add_page(list_entries(socket, []))
  end

  @doc "Adds the next page: the entries right after the last row shown."
  @spec load_more(Socket.t()) :: Socket.t()
  def load_more(socket) do
    entries = list_entries(socket, before: cursor(socket.assigns.rows))
    add_page(socket, entries)
  end

  @doc """
  Shows a changed entry: updated in place when it's listed, inserted at its position
  when it matches the filter and search, removed when it no longer does.
  """
  @spec place(Socket.t(), Entry.t()) :: Socket.t()
  def place(socket, %Entry{id: id} = entry) do
    listed? = listed?(socket, id)

    cond do
      not matches?(entry, socket.assigns) -> if listed?, do: remove(socket, id), else: socket
      listed? -> socket |> track(entry) |> stream_insert(:entries, entry)
      true -> insert_row(socket, entry)
    end
  end

  @doc "Removes the row of an entry, if it's listed."
  @spec remove(Socket.t(), Ecto.UUID.t()) :: Socket.t()
  def remove(socket, id) do
    if listed?(socket, id) do
      socket
      |> update(:rows, &List.keydelete(&1, id, 1))
      |> untrack(id)
      |> stream_delete_by_dom_id(:entries, "entry-#{id}")
      |> refill()
    else
      socket
    end
  end

  @doc "Re-renders the row of a listed active entry with its latest progress."
  @spec put_progress(Socket.t(), Ecto.UUID.t(), map()) :: Socket.t()
  def put_progress(socket, id, progress) do
    case socket.assigns.active do
      %{^id => entry} ->
        socket
        |> update(:progress, &Map.put(&1, id, progress))
        |> stream_insert(:entries, entry)

      %{} ->
        socket
    end
  end

  defp list_entries(socket, opts) do
    %{filter: filter, search: search} = socket.assigns
    Entries.list([filter: filter, search: search, limit: @per_page] ++ opts)
  end

  defp add_page(socket, entries) do
    socket
    |> assign(
      rows: socket.assigns.rows ++ Enum.map(entries, &row_key/1),
      end_of_list?: length(entries) < @per_page
    )
    |> track_all(entries)
    |> update(:progress, fn progress, %{active: active} ->
      Map.take(progress, Map.keys(active))
    end)
    |> stream(:entries, entries)
  end

  defp insert_row(socket, entry) do
    %{rows: rows, end_of_list?: end_of_list?} = socket.assigns
    key = row_key(entry)
    index = Enum.count(rows, &newer?(&1, key))
    limit = max(@max_rows, length(rows))

    if index >= limit or (index == length(rows) and not end_of_list?) do
      # It belongs below the rows shown: a later page will bring it.
      socket
    else
      {rows, dropped} = rows |> List.insert_at(index, key) |> Enum.split(limit)

      socket
      |> assign(rows: rows, end_of_list?: end_of_list? and dropped == [])
      |> untrack_all(Enum.map(dropped, fn {_inserted_at, id} -> id end))
      |> track(entry)
      |> stream_insert(:entries, entry, at: index, limit: limit)
    end
  end

  # Once every row shown has left the list, nothing would load the entries below
  # them (no load-more button, no last row to scroll to) and new entries would be
  # taken for older ones: start over with the first page.
  defp refill(%{assigns: %{rows: [], end_of_list?: false}} = socket),
    do: add_page(socket, list_entries(socket, []))

  defp refill(socket), do: socket

  defp track(socket, %Entry{id: id} = entry) do
    if Entry.active?(entry),
      do: update(socket, :active, &Map.put(&1, id, entry)),
      else: untrack(socket, id)
  end

  defp track_all(socket, entries), do: Enum.reduce(entries, socket, &track(&2, &1))

  defp untrack_all(socket, ids), do: Enum.reduce(ids, socket, &untrack(&2, &1))

  defp untrack(socket, id) do
    socket
    |> update(:active, &Map.delete(&1, id))
    |> update(:progress, &Map.delete(&1, id))
  end

  defp listed?(socket, id), do: List.keymember?(socket.assigns.rows, id, 1)

  defp row_key(%Entry{inserted_at: inserted_at, id: id}), do: {inserted_at, id}

  defp cursor([]), do: nil

  defp cursor(rows) do
    {inserted_at, id} = List.last(rows)
    %Entry{inserted_at: inserted_at, id: id}
  end

  # The list order of Entries.list/1: newest first, ties broken by id.
  defp newer?({at_a, id_a}, {at_b, id_b}) do
    case DateTime.compare(at_a, at_b) do
      :gt -> true
      :lt -> false
      :eq -> id_a > id_b
    end
  end

  defp matches?(%Entry{} = entry, %{filter: filter, search: search}),
    do: matches_filter?(entry.status, filter) and matches_search?(entry, search)

  defp matches_filter?(_status, :all), do: true

  defp matches_filter?(status, :active),
    do: status == :queued or status in Entry.active_statuses()

  defp matches_filter?(status, filter), do: status == filter

  # Mirrors the ILIKE search of Entries.list/1.
  defp matches_search?(_entry, ""), do: true

  defp matches_search?(entry, search) do
    needle = String.downcase(search)

    [entry.url, entry.title, entry.chat_title, entry.from_name]
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end
end
