defmodule AnglerWeb.EntryComponents do
  @moduledoc """
  An entry as the entries list shows it: the entry row with its metadata, live
  progress or error, and row actions, plus the host and title every page names an
  entry by.

  All components are styled with the design tokens from `assets/css/app.css`.
  """
  use Phoenix.Component
  use AnglerWeb, :verified_routes

  import AnglerWeb.CommonComponents, only: [relative_time: 1]
  import AnglerWeb.CoreComponents, only: [icon: 1]
  import AnglerWeb.PlatformComponents, only: [platform_tile: 1]
  import AnglerWeb.StatusComponents

  alias Angler.Entries.Entry
  alias AnglerWeb.Format

  @doc "The host an entry's link points to, without a leading `www.`."
  @spec entry_host(Entry.t()) :: String.t() | nil
  def entry_host(%Entry{source_host: host}) when is_binary(host) and host != "",
    do: host |> String.downcase() |> String.replace_prefix("www.", "")

  def entry_host(%Entry{url: url}), do: Format.host(url)

  @doc "The title of an entry, falling back to its link."
  @spec entry_title(Entry.t()) :: String.t()
  def entry_title(%Entry{title: title}) when is_binary(title) and title != "", do: title
  def entry_title(%Entry{url: url}), do: url

  @doc """
  Renders one entry of the entries list: thumbnail (or platform tile), title
  linking to the entry page, metadata, live progress or error, and row actions.

  The whole row is clickable through a stretched link; actions sit above it.
  """
  attr :id, :string, required: true
  attr :entry, Entry, required: true
  attr :progress, :map, default: nil, doc: "transient progress of an active entry"
  attr :thumbnail_url, :string, default: nil

  def entry_row(assigns) do
    assigns = assign(assigns, :host, entry_host(assigns.entry))

    ~H"""
    <li
      id={@id}
      class="group relative flex gap-3 px-4 py-3.5 transition-colors hover:bg-subtle/70 sm:gap-4 sm:px-5"
    >
      <div class="relative size-12 shrink-0 overflow-hidden rounded-lg ring-1 ring-line sm:size-14">
        <img
          :if={@thumbnail_url}
          src={@thumbnail_url}
          alt=""
          loading="lazy"
          class="size-full object-cover"
        />
        <.platform_tile :if={!@thumbnail_url} host={@host} />
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-start justify-between gap-3">
          <.link
            navigate={~p"/entries/#{@entry.id}"}
            title={@entry.url}
            class="line-clamp-2 min-w-0 text-sm font-medium [overflow-wrap:anywhere] sm:line-clamp-1 text-ink outline-none after:absolute after:inset-0 focus-visible:after:ring-2 focus-visible:after:ring-brand/50 focus-visible:after:ring-inset"
          >
            {entry_title(@entry)}
          </.link>
          <.status_badge status={@entry.status} class="shrink-0" />
        </div>

        <div class="mt-1 flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-ink-muted">
          <span :if={@host} class="font-medium">{@host}</span>
          <span :if={@host} aria-hidden="true" class="text-ink-faint">·</span>
          <span class="max-w-48 truncate">{Format.chat_label(@entry)}</span>
          <span :if={sender(@entry)} class="max-w-40 truncate text-ink-faint">
            by {sender(@entry)}
          </span>
          <span aria-hidden="true" class="text-ink-faint">·</span>
          <.relative_time id={"#{@id}-time"} at={@entry.inserted_at} class="text-ink-faint" />
          <span :if={@entry.output_bytes} class="text-ink-faint tabular-nums">
            · {Format.bytes(@entry.output_bytes)}
          </span>
          <span :if={@entry.duration} class="text-ink-faint tabular-nums">
            · {Format.duration(@entry.duration)}
          </span>
          <span
            :if={@entry.transcoded}
            data-role="transcoded"
            class="rounded bg-progress/10 px-1.5 py-px text-[11px] font-medium text-progress"
          >
            transcoded
          </span>
          <span
            :if={@entry.media_kind == :slideshow}
            data-role="slideshow"
            class="rounded bg-brand/10 px-1.5 py-px text-[11px] font-medium text-brand"
          >
            slideshow
          </span>
        </div>

        <.entry_state entry={@entry} progress={@progress} id={@id} />
      </div>

      <%!-- Fixed width (two buttons) keeps the badges of all rows aligned. --%>
      <div class="relative z-10 -mr-1.5 flex w-16.5 shrink-0 items-center justify-end gap-0.5 self-center">
        <.row_action
          :if={Entry.retryable?(@entry)}
          id={"#{@id}-retry"}
          event="retry"
          entry={@entry}
          icon="hero-arrow-path"
          label={if @entry.status == :done, do: "Send again", else: "Retry"}
          confirm={@entry.status == :done && "Download and send this video to the chat again?"}
        />
        <.row_action
          :if={Entry.cancellable?(@entry)}
          id={"#{@id}-cancel"}
          event="cancel"
          entry={@entry}
          icon="hero-no-symbol"
          label="Cancel"
        />
        <.row_action
          :if={not Entry.active?(@entry)}
          id={"#{@id}-delete"}
          event="delete"
          entry={@entry}
          icon="hero-trash"
          label="Delete"
          confirm="Delete this entry and its files?"
          danger
        />
      </div>
    </li>
    """
  end

  defp sender(%Entry{chat_type: "private"}), do: nil
  defp sender(%Entry{from_name: name}) when is_binary(name) and name != "", do: name
  defp sender(%Entry{}), do: nil

  attr :id, :string, required: true
  attr :entry, Entry, required: true
  attr :progress, :map, default: nil

  defp entry_state(%{entry: %Entry{status: status}} = assigns)
       when status in [:downloading, :processing, :uploading] do
    assigns = assign(assigns, :progress, current_progress(assigns.entry, assigns.progress))

    ~H"""
    <div id={"#{@id}-progress"} class="mt-2.5 flex items-center gap-3">
      <.progress_bar
        percent={@progress[:percent]}
        stage={@entry.status}
        label={status_label(@entry.status)}
        class="max-w-xs"
      />
      <p class="min-w-0 truncate text-xs text-ink-muted tabular-nums">
        {progress_text(@entry, @progress)}
      </p>
    </div>
    """
  end

  defp entry_state(%{entry: %Entry{status: :failed}} = assigns) do
    ~H"""
    <p id={"#{@id}-error"} class="mt-1.5 truncate text-xs text-danger" title={@entry.error}>
      <span class="font-medium">{error_kind_label(@entry.error_kind)}:</span>
      {Format.truncate(@entry.error, 200)}
    </p>
    """
  end

  defp entry_state(%{entry: %Entry{status: :queued, error: error}} = assigns)
       when is_binary(error) do
    ~H"""
    <p id={"#{@id}-retry-note"} class="mt-1.5 truncate text-xs text-warning" title={@entry.error}>
      <span class="font-medium">Attempt {@entry.attempts} of {@entry.max_attempts} failed</span>
      · retry due <.relative_time id={"#{@id}-retry-at"} at={@entry.available_at} />
    </p>
    """
  end

  defp entry_state(assigns), do: ~H""

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :entry, Entry, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :confirm, :any, default: nil
  attr :danger, :boolean, default: false

  defp row_action(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-id={@entry.id}
      data-confirm={@confirm}
      title={@label}
      aria-label={@label}
      class={[
        "flex size-8 cursor-pointer items-center justify-center rounded-lg text-ink-faint transition",
        "focus-visible:outline-2 focus-visible:outline-brand phx-click-loading:animate-pulse",
        if(@danger,
          do: "hover:bg-danger/10 hover:text-danger",
          else: "hover:bg-subtle hover:text-ink"
        )
      ]}
    >
      <.icon name={@icon} class="size-4.5" />
    </button>
    """
  end
end
