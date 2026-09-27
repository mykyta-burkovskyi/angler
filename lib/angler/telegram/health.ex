defmodule Angler.Telegram.Health do
  @moduledoc """
  Decides whether the last Telegram error in a receiver status
  (`Angler.Telegram.Receiver.status/0`) is still current, for the dashboard.

  Telegram's `getWebhookInfo` keeps `last_error_message` and `last_error_date` of
  the last failed webhook delivery until another delivery fails: a successful one
  never clears them. So the error is compared with the last update the app
  received (`:last_update_at`):

    * `:none` - no error
    * `:failing` - the receiver reports an error of its own (it clears it once
      things work again), no update arrived after the webhook error, or updates
      are waiting at Telegram while none arrived for a minute (they pile up)
    * `:recovered` - an update arrived after the webhook error: deliveries work
    * `:idle` - no update arrived since the app started (or the error has no date),
      so recovery is unproven, but no updates are waiting at Telegram either
  """

  @typedoc "The state, the error message, and when the error happened (nil if unknown)."
  @type t :: :none | {:failing | :recovered | :idle, String.t(), DateTime.t() | nil}

  # Updates waiting at Telegram while nothing arrived for this long (seconds) are
  # stuck rather than on their way.
  @stuck_after 60

  @doc """
  The health of update deliveries at `now`, from a status map with `:last_error`,
  `:last_update_at` and `:webhook` (the `getWebhookInfo` result or nil).

  Telegram dates have whole seconds, so an update only counts as received after
  the error when it arrived at least a second after `last_error_date`.
  """
  @spec webhook_health(map(), DateTime.t()) :: t()
  def webhook_health(status, now \\ DateTime.utc_now())

  def webhook_health(%{last_error: error}, _now) when is_binary(error) and error != "",
    do: {:failing, error, nil}

  def webhook_health(status, now) do
    webhook = Map.get(status, :webhook) || %{}

    case webhook["last_error_message"] do
      message when is_binary(message) and message != "" ->
        error_at = unix_datetime(webhook["last_error_date"])
        last_update_at = Map.get(status, :last_update_at)
        {state(error_at, last_update_at, pending(webhook), now), message, error_at}

      _none ->
        :none
    end
  end

  defp state(error_at, last_update_at, pending, now) do
    cond do
      stuck?(last_update_at, pending, now) -> :failing
      received_after?(last_update_at, error_at) -> :recovered
      pending == 0 and (last_update_at == nil or error_at == nil) -> :idle
      true -> :failing
    end
  end

  defp stuck?(_last_update_at, 0, _now), do: false
  defp stuck?(nil, _pending, _now), do: true

  defp stuck?(last_update_at, _pending, now),
    do: DateTime.diff(now, last_update_at) >= @stuck_after

  defp received_after?(%DateTime{} = last_update_at, %DateTime{} = error_at),
    do: DateTime.compare(last_update_at, DateTime.add(error_at, 1)) != :lt

  defp received_after?(_last_update_at, _error_at), do: false

  defp pending(%{"pending_update_count" => count}) when is_integer(count) and count > 0, do: count
  defp pending(_webhook), do: 0

  defp unix_datetime(seconds) when is_integer(seconds) and seconds > 0 do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp unix_datetime(_seconds), do: nil
end
