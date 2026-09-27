defmodule AnglerWeb.EntryLive.PanelComponents do
  @moduledoc """
  The detail panels of the entry page (`AnglerWeb.EntryLive`): the video preview,
  media information, processing times, stored files, the source link and the
  Telegram message.
  """
  use AnglerWeb, :html

  alias Angler.Entries.Entry
  alias AnglerWeb.Format

  @doc "Renders the stored video, or why there is none."
  attr :entry, Entry, required: true
  attr :video_url, :string, default: nil
  attr :thumbnail_url, :string, default: nil

  def preview_panel(assigns) do
    ~H"""
    <.panel id="preview-panel" title="Preview" body_class="">
      <div :if={@video_url} class="overflow-hidden rounded-b-xl bg-black">
        <video
          id="entry-video"
          controls
          preload="metadata"
          playsinline
          src={@video_url}
          poster={@thumbnail_url}
          class="mx-auto max-h-[70vh] w-full object-contain"
        ></video>
      </div>
      <.empty_state :if={!@video_url} id="no-preview" icon="hero-film" title="No preview">
        {no_preview_text(@entry)}
      </.empty_state>
    </.panel>
    """
  end

  defp no_preview_text(%Entry{status: :done, purged_at: %DateTime{}}),
    do: "The video was removed from storage by the retention or size limits."

  defp no_preview_text(%Entry{status: :done}), do: "The video isn't stored on this server."

  defp no_preview_text(%Entry{status: status}) when status in [:failed, :cancelled],
    do: "Nothing was stored for this entry."

  defp no_preview_text(%Entry{}), do: "The preview appears here once the video is ready."

  @doc "Renders what is known about the video: duration, resolution, codec and sizes."
  attr :entry, Entry, required: true

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
        <:item title="Title">{or_placeholder(@entry.title)}</:item>
        <:item title="Platform">
          {platform_name(entry_host(@entry)) || or_placeholder(entry_host(@entry))}
        </:item>
        <:item title="Extractor">{or_placeholder(@entry.extractor)}</:item>
      </.list>
    </.panel>
    """
  end

  @doc "Renders the chat and message the entry came from, the reply and the uploaded file."
  attr :entry, Entry, required: true

  def telegram_panel(assigns) do
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
        <:item title="Reply">
          {if @entry.reply_message_id,
            do: "##{@entry.reply_message_id}",
            else: Format.placeholder()}
        </:item>
        <:item title="File ID">
          <span :if={@entry.telegram_file_id} class="flex items-center gap-1">
            <span
              id="entry-file-id"
              class="min-w-0 truncate font-mono text-xs"
              title={@entry.telegram_file_id}
            >
              {Format.truncate(@entry.telegram_file_id, 24)}
            </span>
            <.copy_button
              id="copy-file-id"
              value={@entry.telegram_file_id}
              label="Copy file ID"
            />
          </span>
          <span :if={!@entry.telegram_file_id}>{Format.placeholder()}</span>
        </:item>
      </.list>
    </.panel>
    """
  end

  defp sender(%Entry{from_name: nil, from_id: nil}), do: Format.placeholder()
  defp sender(%Entry{from_name: name, from_id: nil}), do: name
  defp sender(%Entry{from_name: nil, from_id: id}), do: "User #{id}"
  defp sender(%Entry{from_name: name, from_id: id}), do: "#{name} (#{id})"

  defp message(%Entry{message_id: id, message_thread_id: nil}), do: "##{id}"

  defp message(%Entry{message_id: id, message_thread_id: thread}),
    do: "##{id} in thread #{thread}"

  defp or_placeholder(nil), do: Format.placeholder()
  defp or_placeholder(""), do: Format.placeholder()
  defp or_placeholder(value), do: value
end
