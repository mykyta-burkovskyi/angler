defmodule AnglerWeb.EntryLive.PanelComponents do
  @moduledoc """
  The detail panels of the entry page (`AnglerWeb.EntryLive`): media information,
  processing times, stored files, the source link and the Telegram message (the
  preview is in `AnglerWeb.EntryLive.PreviewComponents`).
  """
  use AnglerWeb, :html

  alias Angler.Entries.{Entry, MediaItem}
  alias AnglerWeb.Format

  @doc """
  Renders what is known about the media: a video's duration, resolution, codec and
  sizes, or how many photos and videos an album has and their total size.
  """
  attr :entry, Entry, required: true

  def media_panel(%{entry: %Entry{media_kind: :album}} = assigns) do
    ~H"""
    <.panel id="media-panel" title="Media">
      <.list>
        <:item title="Items">
          <span id="entry-album-items">{item_counts(@entry.media_items)}</span>
        </:item>
        <:item title="Size">{sizes(@entry)}</:item>
        <:item title="Transcoded">{yes_no(@entry.transcoded)}</:item>
      </.list>
    </.panel>
    """
  end

  def media_panel(assigns) do
    ~H"""
    <.panel id="media-panel" title="Media">
      <.list>
        <:item title="Duration">{Format.duration(@entry.duration)}</:item>
        <:item title="Resolution">{resolution(@entry)}</:item>
        <:item title="Video codec">{or_placeholder(@entry.video_codec)}</:item>
        <:item title="Size">{sizes(@entry)}</:item>
        <:item title="Transcoded">{yes_no(@entry.transcoded)}</:item>
        <:item title="Reused upload">{yes_no(@entry.reused_file_id)}</:item>
      </.list>
    </.panel>
    """
  end

  # "5 photos · 2 videos"
  defp item_counts(items) do
    [photo: "photo", video: "video"]
    |> Enum.map(fn {type, noun} -> {Enum.count(items, &(&1.type == type)), noun} end)
    |> Enum.reject(fn {count, _noun} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, noun} -> "#{count} #{noun}#{if count != 1, do: "s"}" end)
    |> or_placeholder()
  end

  defp resolution(%Entry{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: "#{width}×#{height}"

  defp resolution(%Entry{}), do: Format.placeholder()

  defp sizes(%Entry{source_bytes: source, output_bytes: output})
       when is_integer(source) and is_integer(output) and source != output,
       do: "#{Format.bytes(source)} → #{Format.bytes(output)}"

  defp sizes(%Entry{source_bytes: source, output_bytes: output}),
    do: Format.bytes(output || source)

  defp yes_no(true), do: "Yes"
  defp yes_no(_value), do: "No"

  @doc "Renders the attempts and when the entry was queued, started and finished."
  attr :entry, Entry, required: true

  def processing_panel(assigns) do
    ~H"""
    <.panel id="processing-panel" title="Processing">
      <.list>
        <:item title="Attempts">{@entry.attempts} of {@entry.max_attempts}</:item>
        <:item title="Queued">{Format.datetime(@entry.inserted_at)}</:item>
        <:item title="Started">{Format.datetime(@entry.started_at)}</:item>
        <:item title="Finished">{Format.datetime(@entry.finished_at)}</:item>
        <:item title="Took">
          {Format.elapsed(@entry.started_at, @entry.finished_at)}
        </:item>
      </.list>
    </.panel>
    """
  end

  @doc "Renders where the entry's files are stored, their size, and when they were deleted."
  attr :entry, Entry, required: true

  def storage_panel(assigns) do
    ~H"""
    <.panel id="storage-panel" title="Storage">
      <.list>
        <:item title="Path">
          <span :if={@entry.storage_path} class="flex items-start gap-1">
            <span class="min-w-0 font-mono text-xs break-all">{@entry.storage_path}</span>
            <.copy_button id="copy-path" value={@entry.storage_path} label="Copy path" />
          </span>
          <span :if={!@entry.storage_path}>{Format.placeholder()}</span>
        </:item>
        <:item title="Stored">{Format.bytes(@entry.stored_bytes)}</:item>
        <:item title="Files deleted">{Format.datetime(@entry.purged_at)}</:item>
      </.list>
    </.panel>
    """
  end

  @doc "Renders the link the entry came from, its title, platform and extractor."
  attr :entry, Entry, required: true

  def source_panel(assigns) do
    ~H"""
    <.panel id="source-panel" title="Source">
      <.list>
        <:item title="Link">
          <span class="flex items-start gap-1">
            <a
              id="entry-url"
              href={@entry.url}
              target="_blank"
              rel="noopener noreferrer"
              class="min-w-0 font-medium break-all text-brand hover:underline"
            >
              {@entry.url}
            </a>
            <.copy_button id="copy-url" value={@entry.url} label="Copy link" />
          </span>
        </:item>
        <:item title="Title">
          <%!-- An album's text is shown in full under its preview. --%>
          <span
            class={@entry.media_kind == :album && "line-clamp-4"}
            title={@entry.media_kind == :album && @entry.title}
          >
            {or_placeholder(@entry.title)}
          </span>
        </:item>
        <:item title="Platform">
          {platform_name(entry_host(@entry)) || or_placeholder(entry_host(@entry))}
        </:item>
        <:item title="Extractor">{or_placeholder(@entry.extractor)}</:item>
      </.list>
    </.panel>
    """
  end

  @doc """
  Renders the chat and message the entry came from, the reply and the uploaded
  file, or for an album how many of its items were sent and its first message.
  """
  attr :entry, Entry, required: true

  def telegram_panel(assigns) do
    # Albums are never sent again from a file id.
    assigns =
      assign(assigns,
        album?: assigns.entry.media_kind == :album,
        file_id: assigns.entry.media_kind != :album && assigns.entry.telegram_file_id
      )

    ~H"""
    <.panel id="telegram-panel" title="Telegram">
      <.list>
        <:item title="Chat">{Format.chat_label(@entry)}</:item>
        <:item title="Chat type">{or_placeholder(@entry.chat_type)}</:item>
        <:item title="Chat ID">
          <span class="font-mono text-xs">{@entry.chat_id}</span>
        </:item>
        <:item title="Sender">{sender(@entry)}</:item>
        <:item title="Message">{message(@entry)}</:item>
        <:item :if={@album?} title="Sent">
          <span id="entry-sent-items" class="tabular-nums">{sent_items(@entry.media_items)}</span>
        </:item>
        <:item title={if @album?, do: "First message", else: "Reply"}>
          {if @entry.reply_message_id,
            do: "##{@entry.reply_message_id}",
            else: Format.placeholder()}
        </:item>
        <:item title="File ID">
          <span :if={@file_id} class="flex items-center gap-1">
            <span id="entry-file-id" class="min-w-0 truncate font-mono text-xs" title={@file_id}>
              {Format.truncate(@file_id, 24)}
            </span>
            <.copy_button id="copy-file-id" value={@file_id} label="Copy file ID" />
          </span>
          <span :if={!@file_id}>{Format.placeholder()}</span>
        </:item>
      </.list>
    </.panel>
    """
  end

  defp sender(%Entry{from_name: nil, from_id: nil}), do: Format.placeholder()
  defp sender(%Entry{from_name: name, from_id: nil}), do: name
  defp sender(%Entry{from_name: nil, from_id: id}), do: "User #{id}"
  defp sender(%Entry{from_name: name, from_id: id}), do: "#{name} (#{id})"

  defp sent_items([]), do: Format.placeholder()

  # "1 of 1 item", "2 of 5 items"
  defp sent_items(items) do
    total = length(items)
    "#{Enum.count(items, &MediaItem.delivered?/1)} of #{total} item#{if total != 1, do: "s"}"
  end

  defp message(%Entry{message_id: id, message_thread_id: nil}), do: "##{id}"

  defp message(%Entry{message_id: id, message_thread_id: thread}),
    do: "##{id} in thread #{thread}"

  defp or_placeholder(nil), do: Format.placeholder()
  defp or_placeholder(""), do: Format.placeholder()
  defp or_placeholder(value), do: value
end
