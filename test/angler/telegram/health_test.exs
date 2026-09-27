defmodule Angler.Telegram.HealthTest do
  use ExUnit.Case, async: true

  alias Angler.Telegram.Health

  @now ~U[2026-09-27 12:00:00Z]
  @error "Wrong response from the webhook: 502 Bad Gateway"

  defp ago(seconds), do: DateTime.add(@now, -seconds)

  # A webhook-mode status whose getWebhookInfo reported `@error` `error_age` seconds
  # ago (nil: no error) with `pending` updates waiting.
  defp status(error_age, last_update_at, pending, overrides \\ %{}) do
    webhook =
      if error_age,
        do: %{
          "url" => "https://angler.example/telegram/webhook",
          "pending_update_count" => pending,
          "last_error_message" => @error,
          "last_error_date" => DateTime.to_unix(ago(error_age))
        },
        else: %{
          "url" => "https://angler.example/telegram/webhook",
          "pending_update_count" => pending
        }

    Map.merge(
      %{
        mode: :webhook,
        bot: nil,
        last_error: nil,
        last_update_at: last_update_at,
        webhook: webhook
      },
      overrides
    )
  end

  defp state(status), do: status |> Health.webhook_health(@now) |> elem(0)

  describe "webhook_health/2" do
    test "is :none without an error" do
      assert Health.webhook_health(status(nil, nil, 0), @now) == :none
      assert Health.webhook_health(status(nil, ago(5), 3), @now) == :none

      assert Health.webhook_health(%{mode: :disabled, last_error: nil, webhook: nil}, @now) ==
               :none

      empty = status(600, nil, 0, %{webhook: %{"last_error_message" => ""}})
      assert Health.webhook_health(empty, @now) == :none
    end

    test "returns the webhook error with its date" do
      assert Health.webhook_health(status(600, ago(5), 0), @now) ==
               {:recovered, @error, ago(600)}
    end

    # {error age, last update age (nil: none since boot), pending updates} => state
    for {error_age, update_age, pending, expected} <- [
          # An update arrived after the error.
          {600, 5, 0, :recovered},
          {600, 590, 0, :recovered},
          # ...and updates are waiting, but others keep arriving.
          {600, 5, 4, :recovered},
          {600, 59, 4, :recovered},
          # Updates wait while nothing arrived for a minute: they pile up.
          {600, 60, 4, :failing},
          {600, 300, 1, :failing},
          # Nothing arrived after the error.
          {600, 700, 0, :failing},
          {30, 40, 2, :failing},
          # Telegram dates have whole seconds: the same second doesn't count as after.
          {600, 600, 0, :failing},
          {600, 599, 0, :recovered},
          # Nothing arrived since the app started (restart).
          {600, nil, 0, :idle},
          {5, nil, 0, :idle},
          {600, nil, 1, :failing}
        ] do
      @tag error_age: error_age, update_age: update_age, pending: pending, expected: expected
      test "error #{error_age} s ago, last update #{inspect(update_age)} s ago, #{pending} pending: #{expected}",
           context do
        last_update_at = context.update_age && ago(context.update_age)
        status = status(context.error_age, last_update_at, context.pending)

        assert state(status) == context.expected
      end
    end

    test "prefers the receiver's own error, which is always current" do
      status = status(600, ago(5), 0, %{last_error: "Telegram getMe failed (401): Unauthorized"})

      assert Health.webhook_health(status, @now) ==
               {:failing, "Telegram getMe failed (401): Unauthorized", nil}

      polling = %{mode: :polling, last_error: "poller stopped: killed", webhook: nil}
      assert Health.webhook_health(polling, @now) == {:failing, "poller stopped: killed", nil}
    end

    test "can't tell whether an error without a date recovered" do
      webhook = %{"last_error_message" => @error, "pending_update_count" => 0}
      status = status(nil, ago(5), 0, %{webhook: webhook})
      assert Health.webhook_health(status, @now) == {:idle, @error, nil}

      status = status(nil, ago(5), 2, %{webhook: Map.put(webhook, "pending_update_count", 2)})
      assert Health.webhook_health(status, @now) == {:failing, @error, nil}

      bad_date = Map.put(webhook, "last_error_date", "yesterday")

      assert {:idle, @error, nil} =
               Health.webhook_health(status(nil, nil, 0, %{webhook: bad_date}))
    end

    test "treats a missing pending count as nothing waiting" do
      webhook = %{"last_error_message" => @error, "last_error_date" => DateTime.to_unix(ago(60))}

      assert state(status(nil, nil, 0, %{webhook: webhook})) == :idle
      assert state(status(nil, ago(5), 0, %{webhook: webhook})) == :recovered
    end

    test "works on a status without :last_update_at" do
      status = status(600, nil, 0) |> Map.delete(:last_update_at)
      assert state(status) == :idle
    end
  end
end
