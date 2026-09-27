defmodule AnglerWeb.CommonComponents do
  @moduledoc """
  Generic building blocks of the dashboard pages: panels, empty states, copy
  buttons and relative times.

  All components are styled with the design tokens from `assets/css/app.css`.
  """
  use Phoenix.Component

  import AnglerWeb.CoreComponents, only: [icon: 1]

  alias AnglerWeb.Format
  alias Phoenix.LiveView.JS

  @doc "Renders a card with a title, an optional description and header actions."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  attr :body_class, :any, default: "p-5"
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-line bg-surface shadow-xs", @class]}>
      <header class="flex items-start justify-between gap-4 border-b border-line px-5 py-3.5">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-ink">{@title}</h2>
          <p :if={@description} class="mt-0.5 text-xs text-ink-muted">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "Renders a friendly placeholder for missing or empty content."
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, doc: "a short explanation"
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col items-center px-6 py-14 text-center", @class]}>
      <div class="flex size-12 items-center justify-center rounded-2xl bg-subtle text-ink-faint ring-1 ring-line">
        <.icon name={@icon} class="size-6" />
      </div>
      <h3 class="mt-4 text-sm font-semibold text-ink">{@title}</h3>
      <p :if={@inner_block != []} class="mt-1 max-w-sm text-sm text-balance text-ink-muted">
        {render_slot(@inner_block)}
      </p>
      <div :if={@actions != []} class="mt-5 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a small button that copies `value` to the clipboard (see the
  `phx:copy` listener in `assets/js/app.js`).
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: "Copy"

  def copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={JS.dispatch("phx:copy")}
      data-copy={@value}
      title={@label}
      aria-label={@label}
      class="group -my-1 inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-md align-middle text-ink-faint transition hover:bg-subtle hover:text-ink"
    >
      <.icon name="hero-clipboard-document-mini" class="size-3.5 group-data-copied:hidden" />
      <.icon
        name="hero-check-mini"
        class="hidden size-3.5 text-success group-data-copied:inline-block"
      />
    </button>
    """
  end

  @doc """
  Renders a relative time ("3 min ago") that stays fresh in the browser, with the
  absolute time as a tooltip.
  """
  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :class, :any, default: nil

  def relative_time(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      title={Format.datetime(@at)}
      phx-hook=".RelativeTime"
      phx-update="ignore"
      class={@class}
    >
      {Format.relative_time(@at)}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RelativeTime">
      // Mirrors AnglerWeb.Format.relative_time/2.
      const MINUTE = 60, HOUR = 3600, DAY = 86400

      function describe(date, now) {
        const diff = Math.round((now - date) / 1000)
        const distance = Math.abs(diff)
        const say = (amount) => (diff >= 0 ? `${amount} ago` : `in ${amount}`)

        if (distance < 45) return diff >= 0 ? "just now" : "in a moment"
        if (Math.round(distance / MINUTE) < 60) return say(`${Math.round(distance / MINUTE)} min`)
        if (Math.round(distance / HOUR) < 24) return say(`${Math.round(distance / HOUR)} h`)
        if (Math.round(distance / DAY) < 7) return say(`${Math.round(distance / DAY)} d`)

        const options = {month: "short", day: "numeric"}
        if (date.getFullYear() !== now.getFullYear()) options.year = "numeric"
        return date.toLocaleDateString("en-US", options)
      }

      export default {
        mounted() {
          this.date = new Date(this.el.getAttribute("datetime"))
          this.el.title = this.date.toLocaleString()
          this.refresh()
          this.timer = setInterval(() => this.refresh(), 30_000)
        },
        destroyed() {
          clearInterval(this.timer)
        },
        refresh() {
          this.el.textContent = describe(this.date, new Date())
        }
      }
    </script>
    """
  end
end
