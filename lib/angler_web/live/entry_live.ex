defmodule AnglerWeb.EntryLive do
  @moduledoc """
  Everything about one entry: live status and progress, the full error, source,
  Telegram and processing details, media information, stored files with a preview
  (the video, or an album's photos and videos and its post text), and actions
  (retry, cancel, delete files, delete the entry).
  """
  use AnglerWeb, :live_view

  import AnglerWeb.EntryLive.{OverviewComponents, PanelComponents, PreviewComponents}

  alias Angler.{Entries, Storage}
  alias Angler.Entries.Entry
  alias AnglerWeb.{EntryActions, Format}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Subscribe before reading: a change in between would never be shown otherwise.
    if connected?(socket), do: Entries.subscribe()

    {:ok, socket |> assign(:progress, nil) |> assign_entry(Entries.get(id))}
  end

  @impl true
  def handle_event(_action, _params, %{assigns: %{entry: nil}} = socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket),
    do: {:noreply, run_action(socket, &EntryActions.retry/1, "Queued again.")}

  def handle_event("cancel", _params, socket),
    do: {:noreply, run_action(socket, &EntryActions.cancel/1, "Entry cancelled.")}

  def handle_event("purge", _params, socket),
    do: {:noreply, run_action(socket, &EntryActions.purge_files/1, "Files deleted.")}

  def handle_event("delete", _params, socket) do
    case EntryActions.run(socket.assigns.entry.id, &EntryActions.delete/1) do
      {:ok, _entry} ->
        {:noreply, socket |> put_flash(:info, "Entry deleted.") |> push_navigate(to: ~p"/")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info(
        {:entry_updated, %Entry{id: id} = entry},
        %{assigns: %{entry: %Entry{id: id}}} = socket
      ) do
    {:noreply, assign_entry(socket, entry)}
  end

  def handle_info({:entry_progress, id, progress}, %{assigns: %{entry: %Entry{id: id}}} = socket) do
    {:noreply, assign(socket, :progress, current_progress(socket.assigns.entry, progress))}
  end

  def handle_info({:entry_deleted, id}, %{assigns: %{entry: %Entry{id: id}}} = socket) do
    {:noreply, socket |> put_flash(:info, "The entry was deleted.") |> push_navigate(to: ~p"/")}
  end

  # Events of other entries.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_entry(socket, nil) do
    assign(socket,
      entry: nil,
      page_title: "Entry not found",
      video_url: nil,
      thumbnail_url: nil,
      album: []
    )
  end

  defp assign_entry(socket, %Entry{} = entry) do
    socket
    |> assign(
      entry: entry,
      page_title: entry |> entry_title() |> Format.truncate(60),
      video_url: if(Storage.video_path(entry) != nil, do: ~p"/media/#{entry.id}/video"),
      thumbnail_url:
        if(Storage.thumbnail_path(entry) != nil, do: ~p"/media/#{entry.id}/thumbnail"),
      album: album(entry)
    )
    |> update(:progress, &current_progress(entry, &1))
  end

  # The items of an album with the URLs of their files on disk (the album_item type
  # of PreviewComponents).
  defp album(%Entry{media_kind: :album} = entry) do
    for %{index: index, item: item, path: path, thumbnail_path: thumbnail} <-
          Storage.media_items(entry) do
      %{
        index: index,
        type: item_type(item.type, path),
        url: if(path, do: ~p"/media/#{entry.id}/items/#{index}"),
        thumbnail_url: if(thumbnail, do: ~p"/media/#{entry.id}/items/#{index}/thumbnail")
      }
    end
  end

  defp album(%Entry{}), do: []

  # A file is shown the way AnglerWeb.MediaController serves it: by its name.
  defp item_type(_type, path) when is_binary(path),
    do: if(Path.extname(path) == ".mp4", do: :video, else: :photo)

  defp item_type(type, nil), do: type

  # Acts on the current state of the entry, which may have changed since it was rendered.
  defp run_action(socket, action, done) do
    case EntryActions.run(socket.assigns.entry.id, action) do
      {:ok, entry} -> socket |> assign_entry(entry) |> put_flash(:info, done)
      {:error, message} -> put_flash(socket, :error, message)
    end
  end
end
