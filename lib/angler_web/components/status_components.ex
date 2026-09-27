defmodule AnglerWeb.StatusComponents do
  @moduledoc """
  Where an entry stands in the pipeline: status and error labels, the status
  badge, the progress bar with its one-line description, and the stage steps.

  All components are styled with the design tokens from `assets/css/app.css`.
  """
  use Phoenix.Component

  alias Angler.Entries.Entry
  alias AnglerWeb.Format

  @status_labels %{
    queued: "Queued",
    downloading: "Downloading",
    processing: "Processing",
    uploading: "Uploading",
    done: "Delivered",
    failed: "Failed",
    cancelled: "Cancelled"
  }

  @error_kind_labels %{
    transient: "Temporary error",
    unsupported: "Unsupported link",
    too_large: "Too large",
    unavailable: "Unavailable",
    telegram: "Telegram error",
    timeout: "Timed out",
    internal: "Internal error"
  }

  @stages [:queued, :downloading, :processing, :uploading, :done]

  @doc "Human label of an entry status."
  @spec status_label(Entry.status()) :: String.t()
  def status_label(status), do: Map.fetch!(@status_labels, status)

  @doc "Human label of an error kind (see `Angler.Entries.Entry.error_kinds/0`)."
  @spec error_kind_label(Entry.error_kind() | nil) :: String.t()
  def error_kind_label(nil), do: "Error"
  def error_kind_label(kind), do: Map.fetch!(@error_kind_labels, kind)

  @doc """
  The progress to show for an entry: the transient progress when it belongs to the
  entry's current stage, else nil.
  """
  @spec current_progress(Entry.t(), map() | nil) :: map() | nil
  def current_progress(%Entry{status: status}, %{stage: status} = progress), do: progress
  def current_progress(%Entry{}, _progress), do: nil

  @doc "One line describing an active entry's progress, e.g. `Downloading · 42% · 3.1MiB/s`."
  @spec progress_text(Entry.t(), map() | nil) :: String.t()
  def progress_text(%Entry{} = entry, progress) do
    percent = progress[:percent] && "#{round(progress[:percent])}%"
    detail = progress[:detail] || entry.stage_detail

    [status_label(entry.status), percent, detail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  Renders a colored badge for an entry status. Statuses of work in progress get a
  pulsing dot.
  """
  attr :status, :atom, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={[
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
        status_classes(@status),
        @class
      ]}
    >
      <span class={[
        "size-1.5 rounded-full bg-current",
        @status in Entry.active_statuses() && "motion-safe:animate-pulse"
      ]} />
      {status_label(@status)}
    </span>
    """
  end

  defp status_classes(:queued), do: "bg-ink-faint/10 text-ink-muted ring-ink-faint/25"
  defp status_classes(:downloading), do: "bg-info/10 text-info ring-info/25"
  defp status_classes(:processing), do: "bg-progress/10 text-progress ring-progress/25"
  defp status_classes(:uploading), do: "bg-brand/10 text-brand ring-brand/25"
  defp status_classes(:done), do: "bg-success/10 text-success ring-success/25"
  defp status_classes(:failed), do: "bg-danger/10 text-danger ring-danger/25"
  defp status_classes(:cancelled), do: "bg-subtle text-ink-faint ring-line-strong"

  @doc """
  Renders a progress bar. Without a `percent` it shows an indeterminate animation.
  The color follows the pipeline `stage`.
  """
  attr :percent, :any, default: nil, doc: "0..100, or nil when unknown"
  attr :stage, :atom, default: nil
  attr :label, :string, default: "Progress"
  attr :class, :any, default: nil

  def progress_bar(assigns) do
    ~H"""
    <div
      role="progressbar"
      aria-label={@label}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent && round(@percent)}
      class={["relative h-1.5 w-full overflow-hidden rounded-full bg-line", @class]}
    >
      <div
        :if={@percent}
        class={["h-full rounded-full transition-[width] duration-700 ease-out", stage_fill(@stage)]}
        style={"width: #{Format.percent(@percent, 100)}%"}
      />
      <div
        :if={!@percent}
        class={[
          "absolute inset-y-0 left-0 w-2/5 rounded-full motion-safe:animate-indeterminate",
          stage_fill(@stage)
        ]}
      />
    </div>
    """
  end

  defp stage_fill(:downloading), do: "bg-info"
  defp stage_fill(:processing), do: "bg-progress"
  defp stage_fill(_stage), do: "bg-brand"

  @doc """
  Renders the pipeline stages of an entry (queued, downloading, processing,
  uploading, delivered) with the current one highlighted. Failed and cancelled
  entries have no position on this path.
  """
  attr :id, :string, required: true
  attr :status, :atom, required: true, values: @stages

  def stage_steps(assigns) do
    assigns = assign(assigns, :steps, steps(assigns.status))

    ~H"""
    <ol id={@id} class="grid grid-cols-5 gap-1.5 sm:gap-2" aria-label="Pipeline stages">
      <li :for={{stage, state} <- @steps} data-state={state} class="min-w-0">
        <div class={["h-1 rounded-full transition-colors duration-500", step_bar(stage, state)]} />
        <p class={[
          "mt-2 truncate text-[11px] font-medium sm:text-xs",
          if(state == :pending, do: "text-ink-faint", else: "text-ink")
        ]}>
          {status_label(stage)}
        </p>
      </li>
    </ol>
    """
  end

  defp steps(status) when status in @stages do
    current = Enum.find_index(@stages, &(&1 == status))

    @stages
    |> Enum.with_index()
    |> Enum.map(fn
      {:done = stage, index} when index == current -> {stage, :complete}
      {stage, index} when index < current -> {stage, :complete}
      {stage, index} when index == current -> {stage, :current}
      {stage, _index} -> {stage, :pending}
    end)
  end

  defp step_bar(_stage, :complete), do: "bg-success"
  defp step_bar(stage, :current), do: [stage_fill(stage), "motion-safe:animate-pulse"]
  defp step_bar(_stage, :pending), do: "bg-line"
end
