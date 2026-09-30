defmodule AnglerWeb.SettingsLiveTest do
  # Not async: settings are a single global row and some tests change the
  # Telegram configuration.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Settings
  alias Angler.Settings.Setting
  alias Angler.Telegram.Receiver

  setup_all do
    # Probing the external tools (`yt-dlp --version` unpacks a whole Python
    # runtime) is slow under a loaded test run; warm the 10 minute cache once so
    # the panel's async load is instant.
    Angler.Media.tool_versions()
    :ok
  end

  setup %{conn: conn} do
    # Telegram calls (if any) made by the status panel or the webhook button.
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    Req.Test.stub(Angler.Telegram, &telegram_stub/1)

    auth = Plug.BasicAuth.encode_basic_auth("admin", "test-password")
    %{conn: put_req_header(conn, "authorization", auth)}
  end

  # `webhook` is merged into the getWebhookInfo result.
  defp telegram_stub(conn, webhook \\ %{}) do
    result =
      case Path.basename(conn.request_path) do
        "getMe" ->
          %{"id" => 1, "is_bot" => true, "first_name" => "Angler", "username" => "angler_bot"}

        "getWebhookInfo" ->
          Map.merge(
            %{
              "url" => "https://angler.example.com/telegram/webhook",
              "pending_update_count" => 3,
              "max_connections" => 40
            },
            webhook
          )

        # A long poll that doesn't return during the test.
        "getUpdates" ->
          receive(do: (:release -> []))

        _method ->
          true
      end

    Req.Test.json(conn, %{"ok" => true, "result" => result})
  end

  # The receiver's mode is fixed when it starts: swaps the application's (disabled)
  # receiver for one in `mode`, whose getWebhookInfo reports `webhook`.
  defp start_receiver(mode, webhook \\ %{}) do
    config = Application.get_env(:angler, Angler.Telegram)
    on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)

    Application.put_env(
      :angler,
      Angler.Telegram,
      Keyword.merge(config, webhook_url: "https://angler.example.com/telegram/webhook")
    )

    Req.Test.stub(Angler.Telegram, &telegram_stub(&1, webhook))
    :ok = Supervisor.terminate_child(Angler.Supervisor, Receiver)
    on_exit(fn -> Supervisor.restart_child(Angler.Supervisor, Receiver) end)
    start_supervised!({Receiver, mode: mode})
  end

  # Records a received update, and waits until the receiver handled (and broadcast) it.
  defp receive_update do
    Receiver.update_received()
    _ = :sys.get_state(Receiver)
  end

  defp webhook_error(age_seconds, pending) do
    %{
      "pending_update_count" => pending,
      "last_error_message" => "Wrong response from the webhook: 502 Bad Gateway",
      "last_error_date" => System.os_time(:second) - age_seconds
    }
  end

  defp field_value(view, name) do
    view
    |> element("#settings-form [name='setting[#{name}]']:not([type=hidden])")
    |> render()
    |> LazyHTML.from_fragment()
    |> then(fn html ->
      case LazyHTML.attribute(html, "value") do
        [value] -> value
        [] -> html |> LazyHTML.text() |> String.trim()
      end
    end)
  end

  describe "settings form" do
    test "shows the current settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert page_title(view) =~ "Settings"
      assert has_element?(view, "#settings-form")
      assert field_value(view, "storage_limit_mb") == "10240"
      assert field_value(view, "retention_hours") == "168"
      assert field_value(view, "allowed_hosts") == Enum.join(Setting.default_hosts(), "\n")
      assert field_value(view, "allowed_chat_ids") == ""

      assert has_element?(view, "#settings-form", "10.2 GB")
      assert has_element?(view, "#settings-form", "About 7d")
      assert has_element?(view, "#setting_upload_limit_mb[placeholder='50']")
      assert has_element?(view, "#settings-form", "Bot API maximum (50 MB)")
      assert has_element?(view, "#setting_failure_replies option[selected][value=private]")
      assert has_element?(view, "#setting_reactions_enabled[checked]")
      assert has_element?(view, "#setting_title_captions[checked]")
      assert has_element?(view, "#settings-form", "Post text as captions")
      assert has_element?(view, "#settings-form", "follows as a separate message")
      assert has_element?(view, "#form-status", "All changes saved")
      refute has_element?(view, "#discard-changes")
    end

    test "validates while typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#settings-form", setting: %{storage_limit_mb: "10"}) |> render_change()

      assert has_element?(view, "#settings-form", "must be greater than or equal to 100")
      assert has_element?(view, "#form-status", "Unsaved changes")
      assert has_element?(view, "#discard-changes")

      view
      |> form("#settings-form", setting: %{storage_limit_mb: "20000", upload_limit_mb: "80"})
      |> render_change()

      refute has_element?(view, "#settings-form", "must be greater than or equal to 100")
      assert has_element?(view, "#settings-form", "20 GB")
      assert has_element?(view, "#settings-form", "must be between 5 and 50")
    end

    test "saves valid settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form",
        setting: %{
          storage_limit_mb: "20000",
          retention_hours: "0",
          history_days: "30",
          max_source_mb: "500",
          max_duration_minutes: "10",
          upload_limit_mb: "45",
          allowed_hosts: "Example.com, https://www.videos.test/path",
          allowed_chat_ids: "-100123\n42",
          failure_replies: "all",
          reactions_enabled: "false",
          title_captions: "false"
        }
      )
      |> render_submit()

      assert has_element?(view, "#flash-info", "Settings saved.")
      assert has_element?(view, "#form-status", "All changes saved")

      assert %Setting{
               storage_limit_mb: 20_000,
               retention_hours: 0,
               history_days: 30,
               max_source_mb: 500,
               max_duration_minutes: 10,
               upload_limit_mb: 45,
               allowed_hosts: ["example.com", "videos.test"],
               allowed_chat_ids: [-100_123, 42],
               failure_replies: :all,
               reactions_enabled: false,
               title_captions: false
             } = Settings.get()

      assert field_value(view, "allowed_hosts") == "example.com\nvideos.test"
      assert field_value(view, "allowed_chat_ids") == "-100123\n42"
      assert has_element?(view, "#settings-form", "deleted right after sending")
    end

    test "turns title captions off and on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#settings-form", setting: %{title_captions: "false"}) |> render_change()
      assert has_element?(view, "#form-status", "Unsaved changes")
      refute has_element?(view, "#setting_title_captions[checked]")

      view |> form("#settings-form", setting: %{title_captions: "false"}) |> render_submit()
      assert %Setting{title_captions: false, reactions_enabled: true} = Settings.get()
      refute has_element?(view, "#setting_title_captions[checked]")
      assert has_element?(view, "#form-status", "All changes saved")

      view |> form("#settings-form", setting: %{title_captions: "true"}) |> render_submit()
      assert %Setting{title_captions: true} = Settings.get()
      assert has_element?(view, "#setting_title_captions[checked]")
    end

    test "clears the chat filter and upload limit", %{conn: conn} do
      {:ok, _} = Settings.update(%{"allowed_chat_ids" => "42", "upload_limit_mb" => "45"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert field_value(view, "allowed_chat_ids") == "42"
      assert field_value(view, "upload_limit_mb") == "45"

      view
      |> form("#settings-form", setting: %{allowed_chat_ids: "", upload_limit_mb: ""})
      |> render_submit()

      assert %Setting{allowed_chat_ids: [], upload_limit_mb: nil} = Settings.get()
    end

    test "does not save invalid settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form", setting: %{retention_hours: "-1", allowed_hosts: "not a host!"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "Some settings are invalid")
      assert has_element?(view, "#settings-form", "must be greater than or equal to 0")
      assert has_element?(view, "#settings-form", "contains invalid hosts")
      assert Settings.get().retention_hours == 168
    end

    test "resets the allowed sites to the defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form",
        setting: %{allowed_hosts: "example.com", storage_limit_mb: "20000"}
      )
      |> render_change()

      assert field_value(view, "allowed_hosts") == "example.com"

      view |> element("#reset-hosts") |> render_click()

      assert field_value(view, "allowed_hosts") == Enum.join(Setting.default_hosts(), "\n")
      # Other unsaved edits stay.
      assert field_value(view, "storage_limit_mb") == "20000"
    end

    test "counts a value that doesn't parse as an unsaved change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#settings-form", setting: %{retention_hours: "1.5"}) |> render_change()

      assert has_element?(view, "#settings-form", "is invalid")
      assert has_element?(view, "#form-status", "Unsaved changes")

      view |> element("#discard-changes") |> render_click()

      assert field_value(view, "retention_hours") == "168"
      assert has_element?(view, "#form-status", "All changes saved")
    end

    test "discards unsaved changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#settings-form", setting: %{storage_limit_mb: "20000"}) |> render_change()
      view |> element("#discard-changes") |> render_click()

      assert field_value(view, "storage_limit_mb") == "10240"
      assert has_element?(view, "#form-status", "All changes saved")
    end

    test "picks up settings saved elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, _} = Settings.update(%{"retention_hours" => "24"})
      assert field_value(view, "retention_hours") == "24"

      # Unsaved edits survive, untouched fields follow the new values.
      view |> form("#settings-form", setting: %{storage_limit_mb: "20000"}) |> render_change()
      {:ok, _} = Settings.update(%{"retention_hours" => "48", "max_source_mb" => "300"})

      assert field_value(view, "storage_limit_mb") == "20000"
      assert field_value(view, "retention_hours") == "48"
      assert field_value(view, "max_source_mb") == "300"
      assert has_element?(view, "#form-status", "Unsaved changes")
    end
  end

  describe "status panels" do
    test "runs a storage cleanup on demand", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#storage-panel #storage-meter")

      view |> element("#run-cleanup") |> render_click()
      render_async(view, 10_000)

      assert has_element?(view, "#flash-info", "Nothing to clean up")
      refute has_element?(view, "#run-cleanup[disabled]")
    end

    test "shows the Telegram connection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-status", "Disabled")
      assert has_element?(view, "#telegram-status", "None")
      refute has_element?(view, "#telegram-last-update")
      refute has_element?(view, "#register-webhook")
    end

    test "re-registers the webhook in webhook mode", %{conn: conn} do
      start_receiver(:webhook)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-status", "Webhook")

      view |> element("#register-webhook") |> render_click()
      render_async(view, 10_000)

      assert has_element?(view, "#flash-info", "Webhook registered")
    end

    # The receiver logs its failed setup.
    @tag :capture_log
    test "follows the Telegram connection status", %{conn: conn} do
      config = Application.get_env(:angler, Angler.Telegram)
      on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)

      Application.put_env(
        :angler,
        Angler.Telegram,
        Keyword.merge(config, webhook_url: "https://angler.example.com/telegram/webhook")
      )

      # The bot token is wrong at first.
      Req.Test.stub(Angler.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"ok" => false, "error_code" => 401, "description" => "Unauthorized"})
      end)

      :ok = Supervisor.terminate_child(Angler.Supervisor, Receiver)
      on_exit(fn -> Supervisor.restart_child(Angler.Supervisor, Receiver) end)
      Receiver.subscribe()
      start_supervised!({Receiver, mode: :webhook, retry_delay: 60_000})
      assert_receive {:telegram_receiver, %{last_error: error}} when is_binary(error), 5_000

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-last-error", "Unauthorized")
      assert has_element?(view, "#telegram-status", "Not connected")

      # Fixed and registered again (e.g. from another tab).
      Req.Test.stub(Angler.Telegram, &telegram_stub/1)
      :ok = Receiver.register_webhook()
      render_async(view, 10_000)

      refute has_element?(view, "#telegram-last-error")
      assert has_element?(view, "#telegram-status", "@angler_bot")
    end

    test "shows a webhook error in red while deliveries fail", %{conn: conn} do
      start_receiver(:webhook, webhook_error(60, 3))

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(
               view,
               "#telegram-last-error.text-danger[data-health=failing]",
               "502 Bad Gateway"
             )

      assert has_element?(view, "#telegram-status time[id^=telegram-last-error-at-]")
      assert has_element?(view, "#telegram-last-update", "None since the app started")
      refute has_element?(view, "#telegram-recovered")
      refute has_element?(view, "#telegram-idle")
    end

    test "mutes a webhook error that updates arrived after", %{conn: conn} do
      start_receiver(:webhook, webhook_error(600, 0))
      receive_update()

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-last-error[data-health=recovered]", "502 Bad Gateway")
      refute has_element?(view, "#telegram-last-error.text-danger")
      assert has_element?(view, "#telegram-recovered", "delivering normally since then")

      assert has_element?(
               view,
               "#telegram-status time[id^=telegram-last-error-at-]",
               "10 min ago"
             )

      assert has_element?(view, "#telegram-last-update time", "just now")
    end

    test "mutes a webhook error when no updates are waiting after a restart", %{conn: conn} do
      start_receiver(:webhook, webhook_error(600, 0))

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-last-error[data-health=idle]", "502 Bad Gateway")
      refute has_element?(view, "#telegram-last-error.text-danger")
      assert has_element?(view, "#telegram-idle", "no updates waiting")
      assert has_element?(view, "#telegram-last-update", "None since the app started")
    end

    test "mutes a failing webhook error live once an update arrives", %{conn: conn} do
      start_receiver(:webhook, webhook_error(60, 1))

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)
      assert has_element?(view, "#telegram-last-error.text-danger[data-health=failing]")

      # Telegram delivers the waiting update.
      Req.Test.stub(Angler.Telegram, &telegram_stub(&1, webhook_error(60, 0)))
      receive_update()
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-last-error[data-health=recovered]")
      refute has_element?(view, "#telegram-last-error.text-danger")
      assert has_element?(view, "#telegram-status", "Pending updates")
      assert has_element?(view, "#telegram-last-update time", "just now")
    end

    test "shows the last update in polling mode", %{conn: conn} do
      start_receiver(:polling)
      receive_update()

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#telegram-status", "Polling")
      assert has_element?(view, "#telegram-last-update time", "just now")
      refute has_element?(view, "#telegram-status", "Pending updates")
      refute has_element?(view, "#register-webhook")
    end

    test "shows the system and tool versions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 10_000)

      assert has_element?(view, "#system-info", to_string(Application.spec(:angler, :vsn)))
      assert has_element?(view, "#pipeline-state", "Stopped")
      assert has_element?(view, "#system-info", "2 downloading · 2 sending")
      assert has_element?(view, "#tool-versions tr", "yt-dlp")
      assert has_element?(view, "#tool-versions tr", "ffmpeg")
    end

    test "reports why yt-dlp could not be updated", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#update-ytdlp") |> render_click()
      render_async(view, 10_000)

      assert has_element?(view, "#flash-error", "Updating yt-dlp failed")
    end
  end
end
