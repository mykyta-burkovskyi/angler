defmodule AnglerWeb.Layouts do
  @moduledoc """
  The dashboard layouts: the static root document (`layouts/root.html.heex`) and
  the `app/1` shell every LiveView renders into (header, navigation, theme toggle
  and flash notices).
  """
  use AnglerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a sticky header with the Angler logo, the main
  navigation and the theme toggle, the page content, and the flash group.

  ## Examples

      <Layouts.app flash={@flash} active={:entries}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom,
    default: nil,
    values: [nil, :entries, :settings],
    doc: "the navigation item of the current page"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <header class="sticky top-0 z-40 border-b border-line bg-canvas/85 backdrop-blur-md">
        <div class="mx-auto flex h-14 w-full max-w-6xl items-center gap-6 px-4 sm:px-6 lg:px-8">
          <.link
            navigate={~p"/"}
            class="flex shrink-0 items-center gap-2.5 rounded-lg text-ink focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-brand"
          >
            <img src={~p"/images/logo.svg"} alt="" width="28" height="28" class="size-7" />
            <span class="text-[15px] font-semibold tracking-tight">Angler</span>
          </.link>

          <nav aria-label="Main" class="hidden items-center gap-1 sm:flex">
            <.nav_items active={@active} />
          </nav>

          <div class="ml-auto">
            <.theme_toggle />
          </div>
        </div>

        <nav aria-label="Main" class="border-t border-line sm:hidden">
          <div class="mx-auto grid max-w-6xl grid-cols-3 gap-1 px-2 py-1.5">
            <.nav_items active={@active} />
          </div>
        </nav>
      </header>

      <main class="mx-auto w-full max-w-6xl flex-1 px-4 py-6 sm:px-6 sm:py-8 lg:px-8">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :active, :atom, required: true

  defp nav_items(assigns) do
    ~H"""
    <.nav_link navigate={~p"/"} icon="hero-queue-list" active={@active == :entries}>
      Entries
    </.nav_link>
    <.nav_link
      navigate={~p"/settings"}
      icon="hero-adjustments-horizontal"
      active={@active == :settings}
    >
      Settings
    </.nav_link>
    <.nav_link href={~p"/system"} icon="hero-chart-bar" active={false}>
      System
    </.nav_link>
    """
  end

  attr :icon, :string, required: true
  attr :active, :boolean, required: true
  attr :rest, :global, include: ~w(href navigate)
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      aria-current={@active && "page"}
      class={[
        "flex items-center justify-center gap-2 rounded-lg px-3 py-1.5 text-sm font-medium transition",
        "focus-visible:outline-2 focus-visible:outline-brand",
        if(@active,
          do: "bg-surface text-ink shadow-xs ring-1 ring-line",
          else: "text-ink-muted hover:bg-subtle hover:text-ink"
        )
      ]}
      {@rest}
    >
      <.icon name={@icon} class={["size-4", if(@active, do: "text-brand", else: "text-ink-faint")]} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed inset-x-4 top-4 z-50 flex flex-col items-stretch gap-2 sm:inset-x-auto sm:right-6 sm:w-96"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides the system / light / dark theme toggle.

  See <head> in root.html.heex which applies the theme before page load and marks
  the button of the current choice with `aria-pressed` (the server doesn't know it,
  so the buttons are left alone on updates).
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      phx-update="ignore"
      class="relative flex items-center rounded-full border border-line bg-subtle p-0.5"
    >
      <div class="absolute top-0.5 left-0.5 size-7 rounded-full bg-surface shadow-xs ring-1 ring-line transition-[left] duration-200 ease-out [[data-theme=dark]_&]:left-[3.625rem] [[data-theme=light]_&]:left-[1.875rem] [[data-theme-source=system]_&]:left-0.5!" />

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full text-ink-faint transition hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use the system theme"
        title="System"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full text-ink-faint transition hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use the light theme"
        title="Light"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full text-ink-faint transition hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use the dark theme"
        title="Dark"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
