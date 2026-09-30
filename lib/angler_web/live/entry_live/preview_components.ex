defmodule AnglerWeb.EntryLive.PreviewComponents do
  @moduledoc """
  The preview panel of the entry page (`AnglerWeb.EntryLive`): the stored video,
  or the photos and videos of an album in a gallery with the post's text, or why
  there is nothing to show.
  """
  use AnglerWeb, :html

  alias Angler.Entries.Entry

  @typedoc """
  An album item as the gallery shows it: its index (from 0), whether it is a photo
  or a video, and the URLs of its file and thumbnail (`AnglerWeb.MediaController`),
  nil when not on disk.
  """
  @type album_item :: %{
          index: non_neg_integer(),
          type: :photo | :video | nil,
          url: String.t() | nil,
          thumbnail_url: String.t() | nil
        }

  @doc """
  Renders the stored video or album (see `t:album_item/0`), or why there is none,
  followed by an album's post text.
  """
  attr :entry, Entry, required: true
  attr :video_url, :string, default: nil
  attr :thumbnail_url, :string, default: nil
  attr :album, :list, default: [], doc: "the album's items, see `t:album_item/0`"

  def preview_panel(assigns) do
    assigns = assign(assigns, :gallery?, Enum.any?(assigns.album, & &1.url))

    ~H"""
    <.panel id="preview-panel" title="Preview" body_class="">
      <.album_gallery :if={@gallery?} album={@album} />
      <div :if={!@gallery? && @video_url} class="overflow-hidden rounded-b-xl bg-black">
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
      <.empty_state
        :if={!@gallery? && !@video_url}
        id="no-preview"
        icon={if @entry.media_kind == :album, do: "hero-photo", else: "hero-film"}
        title="No preview"
      >
        {no_preview_text(@entry)}
      </.empty_state>
      <.post_text :if={album_text(@entry)} text={album_text(@entry)} />
    </.panel>
    """
  end

  defp no_preview_text(%Entry{status: :done, purged_at: %DateTime{}}),
    do: "The files were removed from storage by the retention or size limits."

  defp no_preview_text(%Entry{status: :done}), do: "The files aren't stored on this server."

  defp no_preview_text(%Entry{status: status}) when status in [:failed, :cancelled],
    do: "Nothing was stored for this entry."

  defp no_preview_text(%Entry{}), do: "The preview appears here once the media is ready."

  # An album's title is the text of its post.
  defp album_text(%Entry{media_kind: :album, title: title})
       when is_binary(title) and title != "",
       do: title

  defp album_text(%Entry{}), do: nil

  attr :album, :list, required: true

  defp album_gallery(assigns) do
    assigns = assign(assigns, :single?, match?([_item], assigns.album))

    ~H"""
    <div
      id="entry-album"
      data-count={length(@album)}
      class={["grid gap-1 p-1", columns(length(@album))]}
    >
      <.album_tile :for={item <- @album} item={item} single?={@single?} />
    </div>
    """
  end

  # Two items side by side, four as a square; otherwise rows of three from sm up.
  defp columns(1), do: "grid-cols-1"
  defp columns(count) when count in [2, 4], do: "grid-cols-2"
  defp columns(_count), do: "grid-cols-2 sm:grid-cols-3"

  attr :item, :map, required: true
  attr :single?, :boolean, required: true

  defp album_tile(assigns) do
    ~H"""
    <div
      id={"entry-media-#{@item.index}"}
      data-type={@item.type}
      class={[
        "group relative overflow-hidden rounded-lg ring-1 ring-line",
        if(@item.url && @item.type == :video, do: "bg-black", else: "bg-subtle"),
        !@single? && "aspect-square"
      ]}
    >
      <a
        :if={@item.url && @item.type != :video}
        href={@item.url}
        target="_blank"
        rel="noopener noreferrer"
        title="Open the photo"
        class="block size-full outline-none focus-visible:ring-2 focus-visible:ring-brand/60 focus-visible:ring-inset"
      >
        <img
          src={@item.url}
          alt={"Photo #{@item.index + 1}"}
          loading="lazy"
          class={[
            "size-full transition duration-300 ease-out motion-safe:group-hover:scale-[1.02]",
            if(@single?, do: "mx-auto max-h-[70vh] object-contain", else: "object-cover")
          ]}
        />
      </a>
      <video
        :if={@item.url && @item.type == :video}
        controls
        preload="metadata"
        playsinline
        src={@item.url}
        poster={@item.thumbnail_url}
        aria-label={"Video #{@item.index + 1}"}
        class={["size-full object-contain", @single? && "mx-auto max-h-[70vh]"]}
      ></video>
      <a
        :if={@item.url && @item.type == :video}
        href={@item.url}
        target="_blank"
        rel="noopener noreferrer"
        title="Open the video"
        aria-label="Open the video"
        class="absolute top-1.5 right-1.5 flex size-7 items-center justify-center rounded-md bg-black/50 text-white/90 backdrop-blur-sm transition hover:bg-black/70 hover:text-white focus-visible:outline-2 focus-visible:outline-brand"
      >
        <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
      </a>
      <div
        :if={!@item.url}
        data-role="missing"
        class="flex size-full flex-col items-center justify-center gap-1 text-ink-faint"
      >
        <.icon name={if @item.type == :video, do: "hero-film", else: "hero-photo"} class="size-5" />
        <span class="text-[11px]">Not stored</span>
      </div>
      <span
        :if={!@single?}
        class="pointer-events-none absolute top-1.5 left-1.5 rounded-md bg-black/50 px-1.5 py-px text-[11px] font-medium text-white tabular-nums backdrop-blur-sm"
      >
        {@item.index + 1}
      </span>
    </div>
    """
  end

  attr :text, :string, required: true

  defp post_text(assigns) do
    ~H"""
    <div class="border-t border-line px-5 py-4">
      <h3 class="text-xs font-medium tracking-wide text-ink-muted uppercase">Post text</h3>
      <pre
        id="entry-post-text"
        class="mt-2 max-h-80 overflow-y-auto font-sans text-sm leading-relaxed whitespace-pre-wrap [overflow-wrap:anywhere] text-ink"
      >{@text}</pre>
    </div>
    """
  end
end
