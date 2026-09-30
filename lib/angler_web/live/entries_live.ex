defmodule AnglerWeb.EntriesLive do
  @moduledoc """
  The dashboard home: headline stats, storage usage, and the live list of entries
  with filter tabs, search and infinite scroll.

  The list is a stream, so the server keeps no entries: `AnglerWeb.EntriesLive.Rows`
  tracks the rows the client shows, to page through the list and place real-time
  updates.
  """
  use AnglerWeb, :live_view

  alias Angler.{Entries, Settings, Storage}
  alias Angler.Entries.Entry
  alias AnglerWeb.{EntryActions, Format}
  alias AnglerWeb.EntriesLive.Rows

  # Entry events refresh the stats at most once per interval; without any, they are
  # still refreshed every period ("in the last 24 hours", free disk space).
  @stats_interval 1_000
  @stats_period 60_000

  @tabs [all: "All", active: "Active", done: "Done", failed: "Failed", cancelled: "Cancelled"]
  @filters Map.new(@tabs, fn {filter, _label} -> {Atom.to_string(filter), filter} end)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Entries.subscribe()
      # The storage limit shown comes from the settings.
      Settings.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: "Entries", live?: connected?(socket), stats_timer: nil, progress: %{})
     |> stream_configure(:entries, dom_id: &"entry-#{&1.id}")
     |> load_stats()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(@filters, params["filter"], :all)
    search = search_param(params["q"])

    {:noreply,
     socket
     |> assign(filter: filter, search: search, search_form: to_form(%{"q" => search}))
     |> Rows.reset()}
  end

  defp search_param(query) when is_binary(query), do: String.trim(query)
  defp search_param(_query), do: ""

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    %{filter: filter, search: search} = socket.assigns

    case search_param(query) do
      ^search -> {:noreply, socket}
      query -> {:noreply, push_patch(socket, to: entries_path(filter, query))}
    end
  end

  def handle_event("load-more", _params, %{assigns: %{end_of_list?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("load-more", _params, socket), do: {:noreply, Rows.load_more(socket)}

  # Rows follow the broadcasts of the changes. Removing a deleted row right away would
  # let the broadcasts of its cancel and purge, which come before the deletion's,
  # show it again for a moment.
  def handle_event("retry", %{"id" => id}, socket),
    do: {:noreply, run_action(socket, id, &EntryActions.retry/1, "Queued again.")}

  def handle_event("cancel", %{"id" => id}, socket),
    do: {:noreply, run_action(socket, id, &EntryActions.cancel/1, "Entry cancelled.")}

  def handle_event("delete", %{"id" => id}, socket),
    do: {:noreply, run_action(socket, id, &EntryActions.delete/1, "Entry deleted.")}

  @impl true
  def handle_info({:entry_updated, %Entry{} = entry}, socket) do
    {:noreply, socket |> Rows.place(entry) |> schedule_stats()}
  end

  def handle_info({:entry_deleted, id}, socket) do
    {:noreply, socket |> Rows.remove(id) |> schedule_stats()}
  end

  def handle_info({:entry_progress, id, progress}, socket) do
    {:noreply, Rows.put_progress(socket, id, progress)}
  end

  def handle_info({:settings_updated, _setting}, socket) do
    {:noreply, schedule_stats(socket)}
  end

  def handle_info(:refresh_stats, socket) do
    {:noreply, socket |> assign(:stats_timer, nil) |> load_stats()}
  end

  ## Actions

  defp run_action(socket, id, action, done) do
    case EntryActions.run(id, action) do
      {:ok, _entry} -> put_flash(socket, :info, done)
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  ## Stats

  defp load_stats(socket) do
    socket
    |> assign(stats: Entries.stats(), usage: Storage.usage())
    |> schedule_stats(@stats_period)
  end

  # One timer refreshes the stats: within `delay` unless it's already due sooner.
  defp schedule_stats(socket, delay \\ @stats_interval) do
    %{stats_timer: timer} = socket.assigns

    cond do
      not connected?(socket) ->
        socket

      timer != nil and due_within?(timer, delay) ->
        socket

      true ->
        if timer, do: Process.cancel_timer(timer)
        assign(socket, :stats_timer, Process.send_after(self(), :refresh_stats, delay))
    end
  end

  # A timer that already fired has its message waiting in the mailbox.
  defp due_within?(timer, delay) do
    case Process.read_timer(timer) do
      false -> true
      remaining -> remaining <= delay
    end
  end

  ## Template helpers

  defp tabs, do: @tabs

  defp tab_count(stats, :all), do: stats.total
  defp tab_count(stats, :active), do: stats.by_status.queued + in_progress(stats)
  defp tab_count(stats, status), do: Map.fetch!(stats.by_status, status)

  defp in_progress(stats),
    do: stats.by_status |> Map.take(Entry.active_statuses()) |> Map.values() |> Enum.sum()

  defp entries_path(filter, search) do
    params = [filter: filter != :all && filter, q: search != "" && search]
    ~p"/?#{Enum.filter(params, fn {_key, value} -> value end)}"
  end

  defp thumbnail_url(%Entry{status: :done} = entry) do
    if Storage.thumbnail_path(entry) != nil, do: ~p"/media/#{entry.id}/thumbnail"
  end

  defp thumbnail_url(%Entry{}), do: nil

  attr :filter, :atom, required: true
  attr :search, :string, required: true

  defp list_empty_state(%{search: search} = assigns) when search != "" do
    ~H"""
    <.empty_state id="entries-empty" icon="hero-magnifying-glass" title="No matches">
      No entries match “{@search}”.
      <:actions>
        <.button patch={entries_path(@filter, "")} size="sm">Clear search</.button>
      </:actions>
    </.empty_state>
    """
  end

  defp list_empty_state(assigns) do
    {icon, title, text} = empty_state_copy(assigns.filter)
    assigns = assign(assigns, icon: icon, title: title, text: text)

    ~H"""
    <.empty_state id="entries-empty" icon={@icon} title={@title}>{@text}</.empty_state>
    """
  end

  defp empty_state_copy(:all),
    do:
      {"hero-inbox", "No entries yet",
       "Post a link in a chat with the bot and it will show up here."}

  defp empty_state_copy(:active),
    do:
      {"hero-bolt", "Nothing in progress",
       "Links show up here while they're downloaded, processed and sent."}

  defp empty_state_copy(:done),
    do: {"hero-check-circle", "No deliveries yet", "Everything sent to your chats shows up here."}

  defp empty_state_copy(:failed),
    do: {"hero-face-smile", "No failures", "Links that couldn't be delivered show up here."}

  defp empty_state_copy(:cancelled),
    do:
      {"hero-no-symbol", "Nothing cancelled",
       "Entries cancelled from the dashboard show up here."}
end
