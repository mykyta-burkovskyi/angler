defmodule AnglerWeb.StatComponents do
  @moduledoc """
  Headline figures of the dashboard: stat cards and the storage meter.

  All components are styled with the design tokens from `assets/css/app.css`.
  """
  use Phoenix.Component

  import AnglerWeb.CoreComponents, only: [icon: 1]

  alias AnglerWeb.Format

  @doc "Renders a numeric headline stat with an icon and an optional caption."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :brand, :success, :danger]
  attr :pulse, :boolean, default: false, doc: "draws attention to work in progress"
  slot :inner_block, doc: "a short caption below the value"

  def stat_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-line bg-surface p-4 shadow-xs">
      <div class="flex items-start justify-between gap-3">
        <p class="text-xs font-medium tracking-wide text-ink-muted uppercase">{@label}</p>
        <span class={[
          "relative flex size-8 items-center justify-center rounded-lg",
          tone_classes(@tone)
        ]}>
          <span
            :if={@pulse}
            class="absolute inset-0 rounded-lg bg-current opacity-20 motion-safe:animate-ping"
          />
          <.icon name={@icon} class="size-4" />
        </span>
      </div>
      <p data-role="value" class="mt-1 text-3xl font-semibold tracking-tight text-ink tabular-nums">
        {@value}
      </p>
      <p :if={@inner_block != []} class="mt-1 text-xs text-ink-faint">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  defp tone_classes(:neutral), do: "bg-subtle text-ink-muted"
  defp tone_classes(:brand), do: "bg-brand/10 text-brand"
  defp tone_classes(:success), do: "bg-success/10 text-success"
  defp tone_classes(:danger), do: "bg-danger/10 text-danger"

  @doc """
  Renders how much of the storage limit the kept media uses, from
  `Angler.Storage.usage/0`. Turns amber above 75% and red above 90%.
  """
  attr :id, :string, required: true
  attr :usage, :map, required: true

  def storage_meter(assigns) do
    assigns =
      assign(
        assigns,
        :percent,
        Format.percent(assigns.usage.used_bytes, assigns.usage.limit_bytes)
      )

    ~H"""
    <div id={@id}>
      <div class="flex items-baseline justify-between gap-3">
        <p class="text-sm text-ink-muted">
          <span data-role="used" class="text-base font-semibold text-ink tabular-nums">
            {Format.bytes(@usage.used_bytes)}
          </span>
          of <span data-role="limit" class="tabular-nums">{Format.bytes(@usage.limit_bytes)}</span>
        </p>
        <p data-role="percent" class="text-sm font-medium text-ink-muted tabular-nums">
          {round(@percent)}%
        </p>
      </div>
      <div
        role="meter"
        aria-label="Storage used"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={round(@percent)}
        class="mt-2 h-2 overflow-hidden rounded-full bg-line"
      >
        <div
          data-level={meter_level(@percent)}
          class={[
            "h-full rounded-full transition-[width] duration-700 ease-out",
            meter_fill(@percent)
          ]}
          style={"width: #{@percent}%"}
        />
      </div>
      <p class="mt-2 text-xs text-ink-faint">
        {files_label(@usage.entries_with_files)}
        <span :if={@usage.disk_free_bytes}>
          · {Format.bytes(@usage.disk_free_bytes)} free on disk
        </span>
      </p>
    </div>
    """
  end

  defp meter_level(percent) when percent >= 90, do: "critical"
  defp meter_level(percent) when percent >= 75, do: "high"
  defp meter_level(_percent), do: "normal"

  defp meter_fill(percent) do
    case meter_level(percent) do
      "critical" -> "bg-danger"
      "high" -> "bg-warning"
      "normal" -> "bg-brand"
    end
  end

  defp files_label(1), do: "1 entry holds files"
  defp files_label(count), do: "#{Format.number(count)} entries hold files"
end
