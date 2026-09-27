defmodule Angler.Telegram do
  @moduledoc """
  Bot API client (Req). All functions return `{:ok, result}` with the decoded
  `result` field of Telegram's response, or `{:error, %Angler.Telegram.Error{}}`.

  Methods that post into a chat go through `Angler.Telegram.RateLimiter` so the
  bot stays within Telegram's per-chat, per-group and global limits. A send waits
  for its slot, and when Telegram still answers 429 the chat is backed off and the
  call is retried (at most twice), as long as the wait is short: up to a minute,
  but only 10 s for `sendVideo`, which holds up one of the pipeline's upload slots.
  Longer waits are returned as a 429 error with `retry_after` set, so the caller
  can reschedule. Reactions and chat actions are best effort: a 429 for them is
  returned right away and doesn't hold back the chat.

  Nothing else is retried here. A `sendVideo` whose request was sent completely
  but never answered (a timeout or closed connection while waiting) fails with the
  `:unconfirmed` kind (see `Angler.Telegram.Error`): Telegram may still post the
  video, so sending it again could post it twice. A local Bot API server answers
  `sendVideo` only after it has uploaded the file to Telegram and closes
  connections that stay silent for 500 s, so local-mode uploads that take longer
  than that end up unconfirmed.

  The bot token is part of every request URL. It never appears in errors or logs
  produced here (see `redact/1`).

  The requests themselves (Req, response decoding, rate limiting and 429 retries)
  are made by `Angler.Telegram.HTTP`.
  """
  alias Angler.Telegram.{Error, HTTP, VideoBody}

  @type result :: {:ok, term()} | {:error, Error.t()}

  @cloud_api_url "https://api.telegram.org"
  @upload_receive_timeout 600_000
  # getUpdates holds the connection for up to `timeout` seconds; wait a bit longer.
  @long_poll_margin 15
  # Less than the default minute (see `Angler.Telegram.HTTP.send_to_chat/5`): a
  # waiting sendVideo holds up one of the pipeline's upload slots.
  @upload_max_wait_ms 10_000

  @doc """
  Calls any Bot API method with JSON params (`nil` values are dropped).
  `opts` are extra `Req` options for this call, e.g. `receive_timeout: 60_000`.
  """
  @spec request(String.t(), map() | keyword(), keyword()) :: result()
  def request(method, params \\ %{}, opts \\ []) do
    HTTP.post(method, [json: Map.new(compact(params))], opts)
  end

  @doc "Returns the bot's own User (`id`, `username`, `first_name`, ...)."
  @spec get_me() :: result()
  def get_me, do: request("getMe")

  @doc """
  Registers the webhook. Options: `:allowed_updates`, `:max_connections`,
  `:drop_pending_updates`.
  """
  @spec set_webhook(String.t(), String.t(), keyword()) :: result()
  def set_webhook(url, secret_token, opts \\ []) do
    request("setWebhook", %{
      url: url,
      secret_token: secret_token,
      allowed_updates: opts[:allowed_updates],
      max_connections: opts[:max_connections],
      drop_pending_updates: opts[:drop_pending_updates]
    })
  end

  @doc "Removes the webhook. Options: `:drop_pending_updates`."
  @spec delete_webhook(keyword()) :: result()
  def delete_webhook(opts \\ []) do
    request("deleteWebhook", %{drop_pending_updates: opts[:drop_pending_updates]})
  end

  @doc """
  Returns the WebhookInfo: `url` (empty when none is set), `pending_update_count`,
  `last_error_date`, `last_error_message`, `max_connections`, `allowed_updates`, ...
  """
  @spec get_webhook_info() :: result()
  def get_webhook_info, do: request("getWebhookInfo")

  @doc """
  Long-polls for updates. Options: `:timeout` (seconds, default 0 = short poll;
  Telegram caps it at 50), `:allowed_updates`, `:limit` (1-100).
  """
  @spec get_updates(integer() | nil, keyword()) :: result()
  def get_updates(offset, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 0)

    request(
      "getUpdates",
      %{
        offset: offset,
        timeout: timeout,
        limit: opts[:limit],
        allowed_updates: opts[:allowed_updates]
      },
      receive_timeout: (timeout + @long_poll_margin) * 1_000
    )
  end

  @doc """
  Sends a video as a reply.

  `video` is `{:path, absolute_path}` (uploaded as multipart, or passed as a local
  path when the local Bot API server runs in `--local` mode) or `{:file_id, id}`.

  Options: `:reply_to_message_id`, `:message_thread_id`, `:chat_type` (for rate limiting),
  `:caption`, `:duration`, `:width`, `:height`, `:thumbnail` (JPEG path),
  `:supports_streaming` (default true).

  Replies never fail because the original message was deleted meanwhile
  (`allow_sending_without_reply`). The thumbnail is only sent with uploads: Telegram
  ignores thumbnails for videos sent by `file_id`.

  Returns the sent Message; the file id is at `result["video"]["file_id"]`
  (or `result["document"]` / `result["animation"]` if Telegram converted it).
  In large chats the message may be scheduled and have `message_id` 0. A request
  that was sent but not answered returns an error of kind `:unconfirmed`.
  """
  @spec send_video(integer(), {:path, Path.t()} | {:file_id, String.t()}, keyword()) :: result()
  def send_video(chat_id, video, opts \\ []) do
    fields =
      compact(
        chat_id: chat_id,
        message_thread_id: opts[:message_thread_id],
        caption: opts[:caption],
        duration: to_integer(opts[:duration]),
        width: to_integer(opts[:width]),
        height: to_integer(opts[:height]),
        supports_streaming: Keyword.get(opts, :supports_streaming, true),
        reply_parameters: reply_parameters(opts[:reply_to_message_id])
      )

    with {:ok, body} <- VideoBody.build(video, fields, opts[:thumbnail]) do
      HTTP.send_to_chat("sendVideo", chat_id, :message, body,
        chat_type: opts[:chat_type],
        receive_timeout: @upload_receive_timeout,
        max_wait: @upload_max_wait_ms,
        track_sent: true
      )
    end
  end

  @doc """
  Sends a text message. Options: `:reply_to_message_id`, `:message_thread_id`,
  `:chat_type`, `:parse_mode`, `:link_preview` (false disables the link preview).
  """
  @spec send_message(integer(), String.t(), keyword()) :: result()
  def send_message(chat_id, text, opts \\ []) do
    fields =
      compact(
        chat_id: chat_id,
        message_thread_id: opts[:message_thread_id],
        text: text,
        parse_mode: opts[:parse_mode],
        reply_parameters: reply_parameters(opts[:reply_to_message_id]),
        link_preview_options: link_preview_options(Keyword.get(opts, :link_preview, true))
      )

    HTTP.send_to_chat("sendMessage", chat_id, :message, [json: Map.new(fields)],
      chat_type: opts[:chat_type]
    )
  end

  @doc "Options: `:message_thread_id`, `:chat_type`."
  @spec send_chat_action(integer(), String.t(), keyword()) :: result()
  def send_chat_action(chat_id, action, opts \\ []) do
    fields =
      compact(chat_id: chat_id, message_thread_id: opts[:message_thread_id], action: action)

    HTTP.send_to_chat("sendChatAction", chat_id, :light, [json: Map.new(fields)],
      chat_type: opts[:chat_type]
    )
  end

  @doc """
  Sets (or with `nil` clears) the bot's reaction on a message. Options:
  `:chat_type`, `:max_wait` (ms to wait for the rate limiter, default a minute;
  a longer wait returns a 429 error without sending anything).
  """
  @spec set_message_reaction(integer(), integer(), String.t() | nil, keyword()) :: result()
  def set_message_reaction(chat_id, message_id, emoji, opts \\ []) do
    reaction = if emoji, do: [%{type: "emoji", emoji: emoji}], else: []
    params = %{chat_id: chat_id, message_id: message_id, reaction: reaction}

    HTTP.send_to_chat(
      "setMessageReaction",
      chat_id,
      :light,
      [json: params],
      Keyword.take(opts, [:chat_type, :max_wait])
    )
  end

  @doc """
  Logs the bot out of the cloud Bot API (`https://api.telegram.org`), regardless
  of the configured `api_base_url`.

  Required once before the bot can be used with a local Bot API server. Run it in
  the running app, e.g.
  `bin/angler rpc "Angler.Telegram.log_out_from_cloud() |> IO.inspect()"`
  (`bin/angler eval` doesn't start the HTTP client this needs). Afterwards the
  cloud API can't be used by this bot for 10 minutes.
  """
  @spec log_out_from_cloud() :: result()
  def log_out_from_cloud, do: HTTP.post("logOut", [json: %{}], api_base_url: @cloud_api_url)

  @doc "Replaces the bot token in `text`, so it can be logged or shown."
  @spec redact(String.t() | nil) :: String.t() | nil
  defdelegate redact(text), to: HTTP

  ## Helpers

  defp compact(params), do: Enum.reject(params, fn {_key, value} -> is_nil(value) end)

  defp reply_parameters(nil), do: nil

  defp reply_parameters(message_id),
    do: %{message_id: message_id, allow_sending_without_reply: true}

  defp link_preview_options(false), do: %{is_disabled: true}
  defp link_preview_options(_enabled), do: nil

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)
end
