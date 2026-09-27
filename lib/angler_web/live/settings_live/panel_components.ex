defmodule AnglerWeb.SettingsLive.PanelComponents do
  @moduledoc """
  The status panels beside the settings form (`AnglerWeb.SettingsLive`): storage
  usage with the cleanup button, the Telegram connection, and the system (pipeline
  and tool versions). The Telegram status and tool versions load asynchronously.
  """
  use AnglerWeb, :html

  alias Angler.Telegram.Health
  alias AnglerWeb.Format
  alias Phoenix.LiveView.AsyncResult

  @doc "Renders the storage usage and the button that runs a cleanup now."
  attr :usage, :map, required: true, doc: "from `Angler.Storage.usage/0`"
  attr :cleaning?, :boolean, required: true, doc: "whether a cleanup is running"

  def storage_panel(assigns) do
    ~H"""
    <.panel id="storage-panel" title="Storage" description="Videos and thumbnails kept on disk.">
      <.storage_meter id="storage-meter" usage={@usage} />
      <.button id="run-cleanup" class="mt-5 w-full" phx-click="cleanup" disabled={@cleaning?}>
        <.icon
          name="hero-sparkles"
          class={["size-4", @cleaning? && "motion-safe:animate-spin"]}
        />
        {if @cleaning?, do: "Cleaning up…", else: "Run cleanup now"}
      </.button>
      <p class="mt-2 text-center text-xs text-ink-faint">
        Applies the retention period and the storage limit right away.
      </p>
    </.panel>
    """
  end

  @doc """
  Renders how updates reach the bot (`Angler.Telegram.Receiver.status/0`), with a
  button to register the webhook again in webhook mode. The last error is red only
  while deliveries are failing (`Angler.Telegram.Health`): Telegram keeps reporting
  a webhook error after deliveries recovered.
  """
  attr :telegram, AsyncResult, required: true
  attr :registering?, :boolean, required: true, doc: "whether a registration is running"

  def telegram_panel(assigns) do
    ~H"""
    <.panel id="telegram-panel" title="Telegram" description="How updates reach the bot.">
      <:actions>
        <.button
          :if={@telegram.ok? and @telegram.result.mode == :webhook}
          id="register-webhook"
          size="sm"
          phx-click="register_webhook"
          disabled={@registering?}
        >
          <.icon
            name="hero-arrow-path"
            class={["size-3.5", @registering? && "motion-safe:animate-spin"]}
          /> Re-register
        </.button>
      </:actions>
      <.async_result :let={status} assign={@telegram}>
        <:loading><.skeleton rows={3} /></:loading>
        <:failed :let={_reason}>
          <p class="text-sm text-danger">Couldn't load the Telegram status.</p>
        </:failed>
        <.list id="telegram-status">
          <:item title="Mode"><.mode_badge mode={status.mode} /></:item>
          <:item title="Bot">
            <span :if={status.bot}>
              <span class="font-medium">@{status.bot["username"]}</span>
              <span class="text-ink-muted">{status.bot["first_name"]}</span>
            </span>
            <span :if={!status.bot} class="text-ink-muted">Not connected</span>
          </:item>
          <:item :if={status.mode == :webhook} title="Webhook">
            <span class="font-mono text-xs break-all">
              {webhook_info(status, "url") || Format.placeholder()}
            </span>
          </:item>
          <:item :if={status.mode == :webhook} title="Pending updates">
            {Format.number(webhook_info(status, "pending_update_count"))}
          </:item>
          <:item :if={status.mode != :disabled} title="Last update">
            <span id="telegram-last-update">
              <.relative_time
                :if={status.last_update_at}
                id={"telegram-last-update-#{DateTime.to_unix(status.last_update_at, :microsecond)}"}
                at={status.last_update_at}
              />
              <span :if={!status.last_update_at} class="text-ink-muted">
                None since the app started
              </span>
            </span>
          </:item>
          <:item title="Last error">
            <.last_error health={Health.webhook_health(status, DateTime.utc_now())} />
          </:item>
        </.list>
      </.async_result>
    </.panel>
    """
  end

  defp webhook_info(%{webhook: webhook}, key) when is_map(webhook), do: webhook[key]
  defp webhook_info(_status, _key), do: nil

  # The relative times get ids that change with the time: their hook ignores
  # updates, so a new time needs a new element.
  attr :health, :any, required: true, doc: "from `Angler.Telegram.Health.webhook_health/2`"

  defp last_error(%{health: :none} = assigns) do
    ~H"""
    <span class="text-ink-muted">None</span>
    """
  end

  defp last_error(%{health: {state, message, at}} = assigns) do
    assigns = assign(assigns, state: state, message: message, at: at)

    ~H"""
    <span
      id="telegram-last-error"
      data-health={@state}
      class={if(@state == :failing, do: "text-danger", else: "text-ink-muted")}
    >
      {@message}
    </span>
    <span :if={@at || @state != :failing} class="mt-0.5 block text-xs text-ink-faint">
      <.relative_time :if={@at} id={"telegram-last-error-at-#{DateTime.to_unix(@at)}"} at={@at} />
      <span :if={@at && @state != :failing} aria-hidden="true">·</span>
      <span :if={@state == :recovered} id="telegram-recovered">
        <.icon name="hero-check-circle-mini" class="size-3.5 align-[-0.2em] text-success" />
        delivering normally since then
      </span>
      <span :if={@state == :idle} id="telegram-idle">no updates waiting</span>
    </span>
    """
  end

  attr :mode, :atom, required: true

  defp mode_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
      mode_classes(@mode)
    ]}>
      <span class="size-1.5 rounded-full bg-current" />
      {@mode |> Atom.to_string() |> String.capitalize()}
    </span>
    """
  end

  defp mode_classes(:webhook), do: "bg-success/10 text-success ring-success/25"
  defp mode_classes(:polling), do: "bg-info/10 text-info ring-info/25"
  defp mode_classes(_disabled), do: "bg-subtle text-ink-muted ring-line-strong"

  @doc """
  Renders the app version, the pipeline and its workers, and the versions of the
  external tools, with a button to update yt-dlp.
  """
  attr :version, :string, required: true
  attr :pipeline, :map, required: true, doc: "from `Angler.Pipeline.info/0`"
  attr :tools, AsyncResult, required: true, doc: "tool name => version (nil when missing)"
  attr :updating_ytdlp?, :boolean, required: true, doc: "whether a yt-dlp update is running"

  def system_panel(assigns) do
    ~H"""
    <.panel id="system-panel" title="System" description="The pipeline and its tools.">
      <:actions>
        <.button
          id="update-ytdlp"
          size="sm"
          phx-click="update_ytdlp"
          disabled={@updating_ytdlp?}
        >
          <.icon
            name="hero-arrow-down-tray"
            class={["size-3.5", @updating_ytdlp? && "motion-safe:animate-bounce"]}
          /> Update yt-dlp
        </.button>
      </:actions>
      <.list id="system-info">
        <:item title="Angler">{@version}</:item>
        <:item title="Pipeline">
          <span
            id="pipeline-state"
            class={[
              "inline-flex items-center gap-1.5 font-medium",
              if(@pipeline.running, do: "text-success", else: "text-ink-muted")
            ]}
          >
            <span class="size-1.5 rounded-full bg-current" />
            {if @pipeline.running, do: "Running", else: "Stopped"}
          </span>
        </:item>
        <:item title="Workers">
          {@pipeline.download_concurrency} downloading · {@pipeline.upload_concurrency} sending
        </:item>
      </.list>

      <h3 class="mt-6 mb-1 text-xs font-medium tracking-wide text-ink-muted uppercase">
        Tools
      </h3>
      <.async_result :let={tools} assign={@tools}>
        <:loading><.skeleton rows={3} /></:loading>
        <:failed :let={_reason}>
          <p class="text-sm text-danger">Couldn't detect the tool versions.</p>
        </:failed>
        <.table id="tool-versions" rows={Enum.sort(tools)}>
          <:col :let={{name, _version}} label="Tool">
            <span class="font-medium">{name}</span>
          </:col>
          <:col :let={{_name, version}} label="Version">
            <span :if={version} class="font-mono text-xs">{version}</span>
            <span :if={!version} class="inline-flex items-center gap-1 text-warning">
              <.icon name="hero-exclamation-triangle-mini" class="size-4" /> Not found
            </span>
          </:col>
        </.table>
      </.async_result>
    </.panel>
    """
  end

  attr :rows, :integer, default: 3

  defp skeleton(assigns) do
    ~H"""
    <div class="space-y-3" aria-busy="true" aria-label="Loading">
      <div :for={row <- 1..@rows} class="flex items-center justify-between gap-4">
        <div class="h-3 w-20 rounded bg-subtle motion-safe:animate-pulse" />
        <div class={[
          "h-3 rounded bg-subtle motion-safe:animate-pulse",
          rem(row, 2) == 0 && "w-24",
          rem(row, 2) == 1 && "w-36"
        ]} />
      </div>
    </div>
    """
  end
end
