defmodule AnglerWeb.SettingsLive do
  @moduledoc """
  The dashboard-adjustable settings (`Angler.Settings`), next to status panels:
  storage usage with an on-demand cleanup, the Telegram connection, and the system
  (pipeline, tool versions, app version).

  Slow calls (the Telegram API, probing external tools, cleanups) run asynchronously
  so they never block the page. Settings saved in another tab are picked up live
  without discarding unsaved edits.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.SettingsLive.{FormComponents, PanelComponents}

  alias Angler.{Media, Pipeline, Settings, Storage}
  alias Angler.Settings.Setting
  alias Angler.Storage.Janitor
  alias Angler.Telegram.Receiver
  alias AnglerWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Settings.subscribe()
      Receiver.subscribe()
    end

    setting = Settings.get()

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       setting: setting,
       max_upload_mb: Settings.max_upload_mb(),
       usage: Storage.usage(),
       pipeline: Pipeline.info(),
       version: to_string(Application.spec(:angler, :vsn)),
       cleaning?: false,
       registering?: false,
       updating_ytdlp?: false
     )
     |> assign_form(Settings.change(setting))
     |> load_telegram()
     |> load_tools()}
  end

  @impl true
  def handle_event("validate", %{"setting" => params}, socket) do
    {:noreply, validate(socket, params)}
  end

  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update(params) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(setting: setting, usage: Storage.usage())
         |> assign_form(Settings.change(setting))
         |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_form(changeset)
         |> put_flash(:error, "Some settings are invalid. Please check the highlighted fields.")}
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply, assign_form(socket, Settings.change(socket.assigns.setting))}
  end

  def handle_event("reset_hosts", _params, socket) do
    params =
      Map.put(
        socket.assigns.form.params,
        "allowed_hosts",
        Enum.join(Setting.default_hosts(), "\n")
      )

    {:noreply, validate(socket, params)}
  end

  def handle_event("cleanup", _params, socket) do
    {:noreply, socket |> assign(:cleaning?, true) |> start_async(:cleanup, &Janitor.run_now/0)}
  end

  def handle_event("register_webhook", _params, socket) do
    {:noreply,
     socket
     |> assign(:registering?, true)
     |> start_async(:register_webhook, &Receiver.register_webhook/0)}
  end

  def handle_event("update_ytdlp", _params, socket) do
    {:noreply,
     socket
     |> assign(:updating_ytdlp?, true)
     |> start_async(:update_ytdlp, &Media.update_ytdlp/0)}
  end

  @impl true
  def handle_async(:cleanup, {:ok, %{purged: purged, freed_bytes: freed_bytes}}, socket) do
    {:noreply,
     socket
     |> assign(cleaning?: false, usage: Storage.usage())
     |> put_flash(:info, cleanup_message(purged, freed_bytes))}
  end

  def handle_async(:cleanup, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:cleaning?, false)
     |> put_flash(:error, failure("Cleanup", {:exit, reason}))}
  end

  def handle_async(:register_webhook, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(:registering?, false)
     |> load_telegram()
     |> put_flash(:info, "Webhook registered with Telegram.")}
  end

  def handle_async(:register_webhook, result, socket) do
    {:noreply,
     socket
     |> assign(:registering?, false)
     |> put_flash(:error, failure("Registering the webhook", result))}
  end

  def handle_async(:update_ytdlp, {:ok, {:ok, version}}, socket) do
    {:noreply,
     socket
     |> assign(:updating_ytdlp?, false)
     |> load_tools()
     |> put_flash(:info, "yt-dlp is now at version #{version}.")}
  end

  def handle_async(:update_ytdlp, result, socket) do
    {:noreply,
     socket
     |> assign(:updating_ytdlp?, false)
     |> put_flash(:error, failure("Updating yt-dlp", result))}
  end

  @impl true
  def handle_info({:settings_updated, %Setting{} = setting}, socket) do
    # Keep unsaved edits on top of the new values instead of discarding them.
    edits = unsaved_edits(socket.assigns.setting, socket.assigns.form.params)
    changeset = Settings.change(setting, edits)
    changeset = if edits == %{}, do: changeset, else: Map.put(changeset, :action, :validate)

    {:noreply,
     socket
     |> assign(setting: setting, usage: Storage.usage())
     |> assign_form(changeset)}
  end

  # The receiver's status changed (e.g. its setup failed or succeeded): refresh the
  # panel, keeping the current one until the new status (with webhook info) is in.
  def handle_info({:telegram_receiver, _status}, socket) do
    {:noreply, load_telegram(socket, reset: false)}
  end

  # The submitted form carries every field; only those that differ from `setting`
  # (or don't parse) were edited.
  defp unsaved_edits(setting, params) do
    changeset = Settings.change(setting, params)
    edited = Map.keys(changeset.changes) ++ Keyword.keys(changeset.errors)
    Map.take(params, Enum.map(edited, &Atom.to_string/1))
  end

  defp validate(socket, params) do
    changeset = Settings.change(socket.assigns.setting, params)
    assign_form(socket, Map.put(changeset, :action, :validate))
  end

  defp assign_form(socket, changeset) do
    # A value that doesn't parse is an unsaved edit too, though it's no change.
    dirty? = changeset.changes != %{} or changeset.errors != []
    assign(socket, form: to_form(changeset), dirty?: dirty?)
  end

  defp load_telegram(socket, opts \\ [reset: true]) do
    assign_async(socket, :telegram, fn -> {:ok, %{telegram: Receiver.status()}} end, opts)
  end

  defp load_tools(socket) do
    assign_async(socket, :tools, fn -> {:ok, %{tools: Media.tool_versions()}} end, reset: true)
  end

  defp cleanup_message(0, _freed_bytes), do: "Nothing to clean up: storage is within its limits."

  defp cleanup_message(1, freed_bytes),
    do: "Removed the files of 1 entry (#{Format.bytes(freed_bytes)})."

  defp cleanup_message(purged, freed_bytes),
    do: "Removed the files of #{purged} entries (#{Format.bytes(freed_bytes)})."

  # The message for a failed async operation: `{:ok, {:error, reason}}` is an
  # expected failure, `{:exit, reason}` a crash (already logged as a crash report).
  defp failure(action, {:ok, {:error, reason}}), do: "#{action} failed: #{describe(reason)}"

  defp failure(action, {:exit, _reason}),
    do: "#{action} failed unexpectedly. See the server logs for details."

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
