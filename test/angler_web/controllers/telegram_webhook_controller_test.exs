defmodule AnglerWeb.TelegramWebhookControllerTest do
  # Not async: some tests change the global Telegram configuration or the sandbox mode.
  use AnglerWeb.ConnCase, async: false

  import Angler.TelegramFixtures
  import ExUnit.CaptureLog

  alias Angler.Entries.Entry
  alias Angler.Repo
  alias Angler.Settings
  alias Angler.Telegram.Receiver

  @secret "test-webhook-secret"
  @tiktok "https://www.tiktok.com/@fisher/video/7301"

  setup do
    stub_bot_api(%{"sendMessage" => %{"message_id" => 1}})
    :ok
  end

  # When the application's receiver last heard of an update. The controller casts to
  # it from this process, so the status call is handled after the cast.
  defp last_update_at, do: Receiver.status().last_update_at

  defp deliver(conn, update, secret \\ @secret) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(
      &if secret, do: put_req_header(&1, "x-telegram-bot-api-secret-token", secret), else: &1
    )
    |> post(~p"/telegram/webhook", Jason.encode!(update))
  end

  test "queues the links of an update", %{conn: conn} do
    message = group_message("🎣 #{@tiktok}?_r=1 and https://youtu.be/abc")
    update = build_update(message)

    conn = deliver(conn, update)

    assert response(conn, 200) == ""

    assert [tiktok, youtube] = Entry |> Repo.all() |> Enum.sort_by(& &1.url)
    assert tiktok.url == @tiktok
    assert tiktok.update_id == update["update_id"]
    assert tiktok.chat_id == message["chat"]["id"]
    assert tiktok.message_id == message["message_id"]
    assert youtube.url == "https://youtu.be/abc"
  end

  test "records when an update was received", %{conn: conn} do
    before = DateTime.utc_now()

    assert conn |> deliver(build_update(group_message("just fishing"))) |> response(200)

    assert %DateTime{} = at = last_update_at()
    assert DateTime.compare(at, before) != :lt
  end

  test "rejects a wrong or missing secret with 403", %{conn: conn} do
    update = build_update(group_message(@tiktok))
    last_update_at = last_update_at()

    assert conn |> deliver(update, "wrong") |> response(403)
    assert build_conn() |> deliver(update, nil) |> response(403)
    assert build_conn() |> deliver(update, "") |> response(403)
    assert Repo.aggregate(Entry, :count) == 0
    # Not from Telegram.
    assert last_update_at() == last_update_at
  end

  test "rejects every request when no secret is configured", %{conn: conn} do
    config = Application.fetch_env!(:angler, Angler.Telegram)
    Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :webhook_secret, nil))
    on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)

    assert conn |> deliver(build_update(group_message(@tiktok)), "") |> response(403)
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "does not duplicate entries when Telegram delivers an update again", %{conn: conn} do
    update = build_update(group_message(@tiktok))

    assert conn |> deliver(update) |> response(200)
    assert build_conn() |> deliver(update) |> response(200)
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "acknowledges messages without links and other updates", %{conn: conn} do
    assert conn |> deliver(build_update(group_message("just fishing"))) |> response(200)

    assert build_conn()
           |> deliver(%{"update_id" => 1, "callback_query" => %{"id" => "1"}})
           |> response(200)

    assert build_conn() |> deliver(%{}) |> response(200)
    assert Repo.aggregate(Entry, :count) == 0
    refute_receive {:bot_api, _, _}, 50
  end

  test "applies the chat and host filters", %{conn: conn} do
    allowed = group_chat()

    {:ok, _} =
      Settings.update(%{
        "allowed_chat_ids" => Integer.to_string(allowed["id"]),
        "allowed_hosts" => "youtube.com"
      })

    assert conn |> deliver(build_update(group_message("https://youtu.be/x"))) |> response(200)

    message = group_message("#{@tiktok} https://www.youtube.com/watch?v=1", allowed)
    assert build_conn() |> deliver(build_update(message)) |> response(200)

    assert [%Entry{url: "https://www.youtube.com/watch?v=1"}] = Repo.all(Entry)
  end

  test "answers /help in private chats", %{conn: conn} do
    message = text_message("/help")

    assert conn |> deliver(build_update(message)) |> response(200)

    assert_receive {:bot_api, "sendMessage", %{"chat_id" => chat_id, "text" => text}}
    assert chat_id == message["chat"]["id"]
    assert text == Angler.Telegram.Updates.help_text()
  end

  test "acknowledges updates that fail to process, so they don't block the chat", %{conn: conn} do
    update = build_update(poison_message())

    log = capture_log(fn -> assert conn |> deliver(update) |> response(200) == "" end)

    assert log =~ "Dropping Telegram update #{update["update_id"]}"
  end

  test "acknowledges an update with a link too long to store, queuing its other links", %{
    conn: conn
  } do
    update = build_update(group_message("#{long_link(3_000)} #{@tiktok}"))

    assert conn |> deliver(update) |> response(200) == ""
    assert [%Entry{url: @tiktok}] = Repo.all(Entry)
  end

  test "answers 503 with retry-after when the database is unavailable", %{conn: conn} do
    # Leave the shared sandbox connection: queries now fail with an ownership error.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    update = build_update(group_message(@tiktok))

    last_update_at = last_update_at()

    {conn, log} = with_log(fn -> deliver(conn, update) end)

    assert response(conn, 503) == ""
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert log =~ "could not store update #{update["update_id"]}"
    # A failed delivery for Telegram: it will report the error.
    assert last_update_at() == last_update_at
  end
end
