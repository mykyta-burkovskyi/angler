defmodule Angler.Telegram.Error do
  @moduledoc """
  A failed Bot API call.

    * `:method` - Bot API method, e.g. `"sendVideo"`
    * `:code` - Telegram `error_code` (usually the HTTP status), nil for transport errors
    * `:description` - Telegram's `description`, or a transport error description
    * `:retry_after` - seconds to wait, from `parameters.retry_after` on 429 responses
    * `:migrate_to_chat_id` - from `parameters.migrate_to_chat_id` (group upgraded to supergroup)
    * `:reason` - the underlying transport exception/term for network errors, else nil
    * `:request_sent` - for transport errors of calls made with `track_sent: true`
      (`Angler.Telegram.send_video/3`): whether the whole request had been sent
      before the error, so Telegram may have carried it out
  """
  defexception [
    :method,
    :code,
    :description,
    :retry_after,
    :migrate_to_chat_id,
    :reason,
    request_sent: false
  ]

  @type t :: %__MODULE__{
          method: String.t() | nil,
          code: integer() | nil,
          description: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          migrate_to_chat_id: integer() | nil,
          reason: term(),
          request_sent: boolean()
        }

  @type kind ::
          :network
          | :unconfirmed
          | :rate_limited
          | :server_error
          | :unauthorized
          | :forbidden
          | :conflict
          | :too_large
          | :chat_migrated
          | :chat_not_found
          | :thread_not_found
          | :reply_not_found
          | :invalid_file
          | :other

  # Checked in order against the lowercased description.
  @description_kinds [
    chat_migrated: ["group chat was upgraded to a supergroup chat"],
    chat_not_found: ["chat not found"],
    thread_not_found: ["message thread not found"],
    reply_not_found: ["message to be replied not found", "reply not found"],
    invalid_file: ["wrong file identifier", "wrong file_id", "file reference", "file_id_invalid"],
    too_large: ["file is too big", "too large"]
  ]

  @impl true
  def message(%__MODULE__{method: method, code: code, description: description}) do
    "Telegram #{method || "request"} failed" <>
      if(code, do: " (#{code})", else: "") <> ": " <> (description || "unknown error")
  end

  @doc """
  Network errors, timeouts, 429 and 5xx responses are worth retrying, unless the
  request was sent before it failed (`:unconfirmed`).
  """
  @spec transient?(t()) :: boolean()
  def transient?(%__MODULE__{code: nil, request_sent: sent?}), do: not sent?
  def transient?(%__MODULE__{code: 429}), do: true
  def transient?(%__MODULE__{code: code}) when code >= 500, do: true
  def transient?(%__MODULE__{}), do: false

  @doc """
  Classifies an error by its code and description:

    * `:network` - no response (transport error or timeout) to a request that was
      not sent completely, or whose sending was not tracked
    * `:unconfirmed` - no response (e.g. timeout, connection closed) after the whole
      request was sent: Telegram may or may not have carried it out
    * `:rate_limited` - 429, see `:retry_after`
    * `:server_error` - 5xx
    * `:unauthorized` - 401, the bot token is wrong or was revoked
    * `:forbidden` - 403, e.g. the bot was blocked by the user, kicked from or is not a
      member of the chat, or the user is deactivated
    * `:conflict` - 409, another `getUpdates` poller runs or a webhook is set
    * `:too_large` - 413 or "file is too big"
    * `:chat_migrated` - the group was upgraded to a supergroup (see `:migrate_to_chat_id`)
    * `:chat_not_found`, `:thread_not_found`, `:reply_not_found`
    * `:invalid_file` - a `file_id` was rejected ("wrong file identifier", "file reference" ...)
    * `:other` - anything else
  """
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{code: nil, request_sent: true}), do: :unconfirmed
  def kind(%__MODULE__{code: nil}), do: :network
  def kind(%__MODULE__{code: 429}), do: :rate_limited
  def kind(%__MODULE__{code: 401}), do: :unauthorized
  def kind(%__MODULE__{code: 403}), do: :forbidden
  def kind(%__MODULE__{code: 409}), do: :conflict
  def kind(%__MODULE__{code: 413}), do: :too_large
  def kind(%__MODULE__{code: code}) when code >= 500, do: :server_error
  def kind(%__MODULE__{migrate_to_chat_id: id}) when is_integer(id), do: :chat_migrated

  def kind(%__MODULE__{description: description}) when is_binary(description) do
    description = String.downcase(description)

    Enum.find_value(@description_kinds, :other, fn {kind, patterns} ->
      if Enum.any?(patterns, &String.contains?(description, &1)), do: kind
    end)
  end

  def kind(%__MODULE__{}), do: :other
end
