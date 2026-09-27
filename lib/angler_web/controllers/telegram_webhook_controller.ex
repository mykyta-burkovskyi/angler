defmodule AnglerWeb.TelegramWebhookController do
  @moduledoc """
  Receives Telegram updates. Verifies `X-Telegram-Bot-Api-Secret-Token`, hands the
  update to `Angler.Telegram.Updates.handle/1` and responds 200 quickly.

  Telegram delivers a chat's updates one at a time and retries anything but a 2xx
  for up to a day, which holds back that chat's later updates. So only temporary
  storage failures get an error (503, retried after a few seconds); an update that
  can't be handled for any other reason is logged and acknowledged (see
  `Angler.Telegram.Updates.handle_safely/1`). 410 is never used: Telegram deletes
  webhooks that keep answering it.

  Every acknowledged update is recorded with
  `Angler.Telegram.Receiver.update_received/2` (a cast, so it never delays the
  response): Telegram never clears the last delivery error it reports, so the
  dashboard compares it with the last update received.
  """
  use AnglerWeb, :controller

  alias Angler.Telegram.{Config, Receiver, Updates}

  @secret_header "x-telegram-bot-api-secret-token"
  @storage_retry_after "5"

  def create(conn, _params) do
    cond do
      not valid_secret?(conn) ->
        send_resp(conn, 403, "")

      Updates.handle_safely(conn.body_params) == :ok ->
        Receiver.update_received()
        send_resp(conn, 200, "")

      true ->
        conn
        |> put_resp_header("retry-after", @storage_retry_after)
        |> send_resp(503, "")
    end
  end

  defp valid_secret?(conn) do
    case {Config.webhook_secret(), get_req_header(conn, @secret_header)} do
      {secret, [token | _]} when is_binary(secret) and secret != "" ->
        Plug.Crypto.secure_compare(token, secret)

      _ ->
        false
    end
  end
end
