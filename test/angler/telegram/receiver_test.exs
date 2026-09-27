defmodule Angler.Telegram.ReceiverTest do
  # Not async: the receiver calls Telegram from tasks and a poller, which need the
  # shared Req.Test mode, and the tests change the global Telegram configuration.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  # Failed setups are logged as warnings.
  @moduletag :capture_log

  alias Angler.Entries.Entry
  alias Angler.Telegram.{Receiver, Updates}

  @webhook_url "https://angler.example/telegram/webhook"
  @bot %{"id" => 1, "is_bot" => true, "username" => "angler_bot", "first_name" => "Angler"}

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    config = Application.fetch_env!(:angler, Angler.Telegram)
    Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :webhook_url, @webhook_url))
    on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)

    Receiver.subscribe()
    %{name: :"#{__MODULE__}.#{System.unique_integer([:positive])}"}
  end

  defp start_receiver(name, opts) do
    start_supervised!({Receiver, [name: name, retry_delay: 10] ++ opts})
  end

  describe "webhook mode" do
    test "registers the webhook on boot and reports its status", %{name: name} do
      stub_bot_api(%{
        "getMe" => @bot,
        "getWebhookInfo" => %{"url" => @webhook_url, "pending_update_count" => 2}
      })

      start_receiver(name, mode: :webhook)

      assert_receive {:bot_api, "getMe", _}
      assert_receive {:bot_api, "setWebhook", params}

      assert params == %{
               "url" => @webhook_url,
               "secret_token" => "test-webhook-secret",
               "allowed_updates" => Updates.allowed_updates(),
               "max_connections" => 40
             }

      assert_receive {:telegram_receiver, %{mode: :webhook, bot: @bot, last_error: nil}}

      assert Receiver.status(name) == %{
               mode: :webhook,
               bot: @bot,
               last_error: nil,
               last_update_at: nil,
               webhook: %{"url" => @webhook_url, "pending_update_count" => 2}
             }
    end

    test "retries failed registrations with backoff", %{name: name} do
      calls = :counters.new(1, [])

      stub_bot_api(%{
        "getMe" => @bot,
        "setWebhook" => fn conn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) < 3 do
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(api_error(400, "Bad Request: bad webhook: Failed to resolve host"))
          else
            Req.Test.json(conn, api_ok(true))
          end
        end
      })

      start_receiver(name, mode: :webhook)

      assert_receive {:telegram_receiver, %{last_error: error}}

      assert error ==
               "Telegram setWebhook failed (400): Bad Request: bad webhook: Failed to resolve host"

      assert_receive {:telegram_receiver, %{last_error: ^error}}
      assert_receive {:telegram_receiver, %{last_error: nil, bot: @bot}}
      assert :counters.get(calls, 1) == 3
    end

    test "reports transport errors without leaking the token", %{name: name} do
      Req.Test.stub(Angler.Telegram, &Req.Test.transport_error(&1, :econnrefused))

      start_receiver(name, mode: :webhook, retry_delay: 60_000)

      assert_receive {:telegram_receiver, %{last_error: error}}
      assert error == "Telegram getMe failed: connection refused"
      assert %{last_error: ^error, webhook: nil, bot: nil} = Receiver.status(name)
    end

    test "register_webhook/1 registers again and returns the outcome", %{name: name} do
      stub_bot_api(%{"getMe" => @bot})
      start_receiver(name, mode: :webhook)
      assert_receive {:telegram_receiver, %{last_error: nil}}

      assert Receiver.register_webhook(name) == :ok
      assert_receive {:bot_api, "setWebhook", _}
      assert_receive {:bot_api, "setWebhook", _}

      stub_bot_api(%{"getMe" => {:error, 401, "Unauthorized"}})

      assert Receiver.register_webhook(name) ==
               {:error, "Telegram getMe failed (401): Unauthorized"}

      assert %{last_error: "Telegram getMe failed (401): Unauthorized"} = Receiver.status(name)
    end

    test "fails without a webhook URL", %{name: name} do
      config = Application.fetch_env!(:angler, Angler.Telegram)
      Application.put_env(:angler, Angler.Telegram, Keyword.delete(config, :webhook_url))
      stub_bot_api()

      start_receiver(name, mode: :webhook, retry_delay: 60_000)

      assert_receive {:telegram_receiver, %{last_error: "no webhook URL configured" <> _}}
      refute_received {:bot_api, _, _}
    end
  end

  describe "disabled mode" do
    test "does nothing", %{name: name} do
      stub_bot_api()
      start_receiver(name, mode: :disabled)

      assert Receiver.status(name) == %{
               mode: :disabled,
               bot: nil,
               webhook: nil,
               last_error: nil,
               last_update_at: nil
             }

      assert Receiver.register_webhook(name) == {:error, "not in webhook mode"}
      refute_receive {:bot_api, _, _}, 50
    end
  end

  test "status/1, register_webhook/1 and update_received/2 work when the receiver is not running" do
    assert Receiver.status(:no_such_receiver) == %{
             mode: :disabled,
             bot: nil,
             webhook: nil,
             last_error: "the Telegram receiver is not running",
             last_update_at: nil
           }

    assert Receiver.register_webhook(:no_such_receiver) ==
             {:error, "the Telegram receiver is not running"}

    assert Receiver.update_received(:no_such_receiver) == :ok
  end

  describe "received updates" do
    @t1 ~U[2026-09-27 12:00:00.000000Z]
    @t2 ~U[2026-09-27 12:00:01.000000Z]
    @t3 ~U[2026-09-27 12:00:02.000000Z]

    test "are reported in the status, the first one broadcast right away", %{name: name} do
      stub_bot_api()
      start_receiver(name, mode: :disabled)

      assert Receiver.update_received(name, @t1) == :ok

      assert_receive {:telegram_receiver, %{mode: :disabled, last_update_at: @t1}}
      assert %{last_update_at: @t1, last_error: nil} = Receiver.status(name)
    end

    test "defaults to now", %{name: name} do
      start_receiver(name, mode: :disabled)
      before = DateTime.utc_now()

      Receiver.update_received(name)

      assert %{last_update_at: %DateTime{} = at} = Receiver.status(name)
      assert DateTime.compare(at, before) != :lt
    end

    test "are broadcast at most once per interval", %{name: name} do
      start_receiver(name, mode: :disabled, broadcast_interval: 60_000)

      Receiver.update_received(name, @t1)
      assert_receive {:telegram_receiver, %{last_update_at: @t1}}

      Receiver.update_received(name, @t2)
      Receiver.update_received(name, @t3)

      # Recorded (the status call is handled after the casts), but not broadcast.
      assert %{last_update_at: @t3} = Receiver.status(name)
      refute_received {:telegram_receiver, _status}
    end

    test "are broadcast with the latest time once the interval is over", %{name: name} do
      start_receiver(name, mode: :disabled, broadcast_interval: 50)

      Receiver.update_received(name, @t1)
      assert_receive {:telegram_receiver, %{last_update_at: @t1}}

      Receiver.update_received(name, @t2)
      Receiver.update_received(name, @t3)

      assert_receive {:telegram_receiver, %{last_update_at: @t3}}, 1_000
    end

    test "keep the latest time when reported out of order", %{name: name} do
      start_receiver(name, mode: :disabled, broadcast_interval: 60_000)

      Receiver.update_received(name, @t2)
      Receiver.update_received(name, @t1)
      GenServer.cast(name, {:update_received, "not a time"})

      assert %{last_update_at: @t2} = Receiver.status(name)
    end

    test "are included in status broadcasts", %{name: name} do
      stub_bot_api(%{"getMe" => {:error, 401, "Unauthorized"}})
      start_receiver(name, mode: :webhook, retry_delay: 60_000, broadcast_interval: 60_000)
      assert_receive {:telegram_receiver, %{last_error: "Telegram getMe failed" <> _}}

      Receiver.update_received(name, @t1)
      assert_receive {:telegram_receiver, %{last_update_at: @t1}}
      Receiver.update_received(name, @t2)

      # Registering again fails again and broadcasts right away, with the latest time.
      assert {:error, _message} = Receiver.register_webhook(name)

      assert_receive {:telegram_receiver,
                      %{last_update_at: @t2, last_error: "Telegram getMe" <> _}}
    end
  end

  describe "polling mode" do
    test "removes the webhook and processes polled updates", %{name: name} do
      test = self()
      first = build_update(group_message("https://youtu.be/one"))
      second = build_update(group_message("https://youtu.be/two"))

      stub_bot_api(%{
        "getMe" => @bot,
        "getUpdates" => fn conn ->
          case conn.body_params["offset"] do
            nil -> Req.Test.json(conn, api_ok([first, second]))
            _offset -> long_poll(conn, test)
          end
        end
      })

      start_receiver(name, mode: :polling, poller: [timeout: 1])

      assert_receive {:bot_api, "deleteWebhook", %{"drop_pending_updates" => false}}
      assert_receive {:bot_api, "getUpdates", params}
      assert params["allowed_updates"] == Updates.allowed_updates()
      assert params["timeout"] == 1
      refute Map.has_key?(params, "offset")

      next_offset = second["update_id"] + 1
      assert_receive {:bot_api, "getUpdates", %{"offset" => ^next_offset}}
      assert_receive {:long_poll, _poller}

      assert ["https://youtu.be/one", "https://youtu.be/two"] ==
               Entry |> Repo.all() |> Enum.map(& &1.url) |> Enum.sort()

      assert_receive {:telegram_receiver, %{last_update_at: %DateTime{}}}

      assert %{mode: :polling, bot: @bot, webhook: nil, last_error: nil, last_update_at: at} =
               Receiver.status(name)

      assert %DateTime{} = at
      assert Receiver.register_webhook(name) == {:error, "not in webhook mode"}
    end

    test "restarts a crashed poller", %{name: name} do
      test = self()
      stub_bot_api(%{"getMe" => @bot, "getUpdates" => &long_poll(&1, test)})

      start_receiver(name, mode: :polling, poller: [timeout: 1])

      assert_receive {:telegram_receiver, %{last_error: nil}}
      assert_receive {:long_poll, poller}
      Process.exit(poller, :kill)

      assert_receive {:telegram_receiver, %{last_error: "poller stopped: killed"}}
      assert_receive {:bot_api, "deleteWebhook", _}
      assert_receive {:telegram_receiver, %{last_error: nil}}
      assert_receive {:long_poll, new_poller}
      assert new_poller != poller
    end
  end

  # Simulates a long poll that doesn't return during the test.
  defp long_poll(conn, test) do
    send(test, {:long_poll, self()})

    receive do
      :release -> Req.Test.json(conn, api_ok([]))
    end
  end
end
