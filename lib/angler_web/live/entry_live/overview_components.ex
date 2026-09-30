defmodule AnglerWeb.EntryLive.OverviewComponents do
  @moduledoc """
  The top of the entry page (`AnglerWeb.EntryLive`): what the entry is, the actions
  on it, and where it stands (its progress through the pipeline, the full error of
  a failed entry, or its cancellation).
  """
  use AnglerWeb, :html

  alias Angler.Entries.Entry
  alias AnglerWeb.Format

  @doc """
  Renders the entry's thumbnail (or platform tile), badges, title and origin, next
  to the actions its status allows.
  """
  attr :entry, Entry, required: true
  attr :video_url, :string, default: nil
  attr :thumbnail_url, :string, default: nil
  attr :album, :list, default: [], doc: "the album's items (see `EntryLive.PreviewComponents`)"

  def entry_header(assigns) do
    ~H"""
    <div class="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
      <div class="flex min-w-0 items-start gap-4">
        <div class="size-14 shrink-0 overflow-hidden rounded-xl ring-1 ring-line sm:size-16">
          <img :if={@thumbnail_url} src={@thumbnail_url} alt="" class="size-full object-cover" />
          <.platform_tile :if={!@thumbnail_url} host={entry_host(@entry)} />
        </div>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.status_badge id="entry-status" status={@entry.status} />
            <span
              :if={@entry.transcoded}
              class="rounded-full bg-progress/10 px-2 py-0.5 text-xs font-medium text-progress"
            >
              Transcoded
            </span>
            <span
              :if={@entry.media_kind == :slideshow}
              id="entry-slideshow"
              class="rounded-full bg-brand/10 px-2 py-0.5 text-xs font-medium text-brand"
            >
              Slideshow
            </span>
            <span
              :if={album_kind(@entry)}
              id="entry-album-badge"
              class="rounded-full bg-brand/10 px-2 py-0.5 text-xs font-medium text-brand"
            >
              {String.capitalize(album_kind(@entry))}
            </span>
          </div>
          <%!-- Post texts can be long: the preview shows an album's in full. --%>
          <h1
            id="entry-title"
            title={entry_title(@entry)}
            class="mt-2 line-clamp-3 text-xl font-semibold tracking-tight break-words text-ink sm:text-2xl"
          >
            {entry_title(@entry)}
          </h1>
          <p
            id="entry-meta"
            class="mt-1 flex flex-wrap items-center gap-x-1.5 text-sm [overflow-wrap:anywhere] text-ink-muted"
          >
            <span :if={entry_host(@entry)}>{entry_host(@entry)} ·</span>
            <span>{Format.chat_label(@entry)} ·</span>
            <span>
              received <.relative_time id="entry-received" at={@entry.inserted_at} />
            </span>
          </p>
        </div>
      </div>

      <.entry_actions
        entry={@entry}
        files?={files?(@entry, [@video_url, @thumbnail_url | Enum.map(@album, & &1.url)])}
      />
    </div>
    """
  end

  attr :entry, Entry, required: true
  attr :files?, :boolean, required: true

  defp entry_actions(assigns) do
    ~H"""
    <div id="entry-actions" class="flex shrink-0 flex-wrap gap-2">
      <.button
        :if={Entry.retryable?(@entry)}
        id="retry-entry"
        phx-click="retry"
        data-confirm={retry_confirm(@entry)}
      >
        <.icon name="hero-arrow-path" class="size-4" />
        {if @entry.status == :done, do: "Send again", else: "Retry"}
      </.button>
      <.button :if={Entry.cancellable?(@entry)} id="cancel-entry" phx-click="cancel">
        <.icon name="hero-no-symbol" class="size-4" /> Cancel
      </.button>
      <.button
        :if={@files? and Entry.terminal?(@entry)}
        id="purge-entry"
        phx-click="purge"
        data-confirm="Delete the stored files? The entry itself stays."
      >
        <.icon name="hero-archive-box-x-mark" class="size-4" /> Delete files
      </.button>
      <.button
        :if={not Entry.active?(@entry)}
        id="delete-entry"
        variant="danger"
        phx-click="delete"
        data-confirm="Delete this entry and its files?"
      >
        <.icon name="hero-trash" class="size-4" /> Delete
      </.button>
    </div>
    """
  end

  defp files?(entry, urls), do: entry.stored_bytes > 0 or Enum.any?(urls)

  @doc """
  Renders where the entry stands: the full error of a failed entry, a notice for a
  cancelled one, and otherwise its pipeline stages with live progress, a pending
  retry, or when it was delivered.
  """
  attr :entry, Entry, required: true
  attr :progress, :map, default: nil, doc: "transient progress of the current stage"

  def status_section(%{entry: %Entry{status: :failed}} = assigns) do
    ~H"""
    <section
      id="entry-error"
      class="rounded-xl border border-danger/25 bg-danger/5 p-5 shadow-xs"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-5 text-danger" />
          <h2 class="text-sm font-semibold text-ink">
            {error_kind_label(@entry.error_kind)}
          </h2>
          <span
            :if={@entry.error_kind}
            class="rounded-md bg-danger/10 px-1.5 py-0.5 font-mono text-[11px] text-danger"
          >
            {@entry.error_kind}
          </span>
        </div>
        <p class="text-xs text-ink-muted">
          Failed after {@entry.attempts} of {@entry.max_attempts} attempts ·
          <.relative_time
            :if={@entry.finished_at}
            id="entry-failed-at"
            at={@entry.finished_at}
          />
        </p>
      </div>
      <pre
        :if={@entry.error}
        id="entry-error-text"
        class="mt-3 max-h-80 overflow-auto rounded-lg bg-surface p-3 font-mono text-xs leading-relaxed break-words whitespace-pre-wrap text-ink ring-1 ring-danger/15"
      >{@entry.error}</pre>
    </section>
    """
  end

  def status_section(%{entry: %Entry{status: :cancelled}} = assigns) do
    ~H"""
    <section
      id="entry-cancelled"
      class="flex items-center gap-3 rounded-xl border border-line bg-surface p-5 text-sm text-ink-muted shadow-xs"
    >
      <.icon name="hero-no-symbol" class="size-5 text-ink-faint" />
      <p>
        Cancelled from the dashboard
        <.relative_time
          :if={@entry.finished_at}
          id="entry-cancelled-at"
          at={@entry.finished_at}
        />. Retry to process it again.
      </p>
    </section>
    """
  end

  def status_section(assigns) do
    ~H"""
    <section
      id="entry-progress"
      class="rounded-xl border border-line bg-surface p-5 shadow-xs"
    >
      <.stage_steps id="entry-stages" status={@entry.status} />

      <div
        :if={Entry.active?(@entry)}
        id="entry-progress-bar"
        class="mt-5 flex items-center gap-3"
      >
        <.progress_bar
          percent={@progress[:percent]}
          stage={@entry.status}
          label={status_label(@entry.status)}
        />
        <p class="max-w-[50%] shrink-0 truncate text-xs text-ink-muted tabular-nums">
          {progress_text(@entry, @progress)}
        </p>
      </div>

      <p
        :if={@entry.status == :queued and not retry_pending?(@entry)}
        class="mt-4 text-sm text-ink-muted"
      >
        Waiting for a worker.
      </p>

      <p :if={@entry.status == :done} class="mt-4 text-sm text-ink-muted">
        Delivered
        <.relative_time :if={@entry.finished_at} id="entry-done-at" at={@entry.finished_at} />
        <span :if={@entry.started_at && @entry.finished_at}>
          · took {Format.elapsed(@entry.started_at, @entry.finished_at)}
        </span>
      </p>

      <div :if={retry_pending?(@entry)} id="entry-retry" class="mt-4">
        <p class="text-sm text-warning">
          <span class="font-medium">
            Attempt {@entry.attempts} of {@entry.max_attempts} failed
            ({error_kind_label(@entry.error_kind)})
          </span>
          · retry due <.relative_time id="entry-retry-at" at={@entry.available_at} />
        </p>
        <pre
          id="entry-error-text"
          class="mt-3 max-h-60 overflow-auto rounded-lg bg-warning/5 p-3 font-mono text-xs leading-relaxed break-words whitespace-pre-wrap text-ink ring-1 ring-warning/20"
        >{@entry.error}</pre>
      </div>
    </section>
    """
  end

  defp retry_pending?(%Entry{status: :queued, error: error}), do: is_binary(error)
  defp retry_pending?(%Entry{}), do: false
end
