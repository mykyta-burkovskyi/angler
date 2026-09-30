defmodule Angler.Telegram.Updates do
  @moduledoc """
  Handles one incoming Telegram Update (from the webhook or the poller): extracts
  links from messages and channel posts, applies the chat/host filters from
  `Angler.Settings`, and queues them with `Angler.Entries.enqueue/1`. Also answers
  `/start` and `/help` in private chats.

  Must be fast and must not call slow external services synchronously except for
  short replies to commands: the webhook responds only after this returns. Replies
  are therefore sent from a task under `Angler.TaskSupervisor`.

  Messages sent by bots are ignored so two bots can't loop. Messages posted on
  behalf of a chat (anonymous group admins, channels) carry a bot as `from` but
  also a `sender_chat`, and are processed. Channel posts Telegram automatically
  forwards to the channel's discussion group are ignored when the channel is an
  allowed chat: the `channel_post` update already covers them, and the group would
  get the video a second time.
  """
  require Logger

  alias Angler.{Entries, Links, Settings, Telegram}

  @message_types ~w(message edited_message channel_post edited_channel_post)
  @allowed_updates @message_types ++ ~w(my_chat_member)
  @max_banner_length 500

  # Postgres errors that may go away on a later delivery: SQLSTATE classes 08
  # (connection), 40 (serialization failure, deadlock), 53 (disk full, out of memory,
  # too many connections), 57 (shutdown, cancelled statement) and 58 (system error),
  # a lock timeout (55P03) and a read-only database (25006).
  @temporary_sqlstate_classes ~w(08 40 53 57 58)
  @temporary_sqlstates ~w(55P03 25006)

  @help_text """
  🎣 I turn links into videos and photos.

  Send me a link to a video or post (TikTok, Instagram, YouTube, X, Reddit, ...) and I'll \
  reply with the video itself, or with the photos and videos of an Instagram post. Add me \
  to a group and I'll do the same for links posted there.

  For groups: Telegram's privacy mode hides ordinary group messages from bots. Make me \
  a group admin, or disable privacy mode for this bot with /setprivacy in @BotFather and \
  then remove and re-add me to the group.\
  """

  @hint_text "Send me a link to a video or post (TikTok, Instagram, YouTube, X, ...) and I'll reply with its media."

  @doc "Update types Angler asks Telegram for (`allowed_updates` of setWebhook / getUpdates)."
  @spec allowed_updates() :: [String.t()]
  def allowed_updates, do: @allowed_updates

  @doc "Text of the reply to `/start` and `/help`."
  @spec help_text() :: String.t()
  def help_text, do: @help_text

  @doc "Returns `{:ok, queued_entries}`; raises/returns error only for storage failures."
  @spec handle(map()) :: {:ok, [Angler.Entries.Entry.t()]} | {:error, term()}
  def handle(%{"my_chat_member" => change}) when is_map(change) do
    log_membership(change)
    {:ok, []}
  end

  def handle(update) when is_map(update) do
    case Enum.find(@message_types, &is_map(update[&1])) do
      nil -> {:ok, []}
      type -> handle_message(update, type, update[type])
    end
  end

  @doc """
  Like `handle/1`, but never raises. Returns `:ok` when the update was handled, or
  can never be (the failure is logged, so a poison update doesn't block its chat),
  and `{:error, message}` after a temporary storage failure, when the update
  should be delivered again later (see `storage_error?/1`).
  """
  @spec handle_safely(map()) :: :ok | {:error, String.t()}
  def handle_safely(update) do
    {:ok, _entries} = handle(update)
    :ok
  rescue
    exception ->
      if storage_error?(exception) do
        storage_failure(update, Exception.message(exception))
      else
        # The banner may quote parts of the update: keep it short.
        banner = Exception.format_banner(:error, exception, __STACKTRACE__)

        Logger.error(
          "Dropping Telegram update #{update_id(update)} that failed to process: " <>
            String.slice(banner, 0, @max_banner_length) <>
            "\n" <> Exception.format_stacktrace(__STACKTRACE__)
        )

        :ok
      end
  end

  @doc """
  Whether an exception raised by `handle/1` is a temporary storage failure (e.g.
  the database is unreachable), so the update should be delivered again later.
  """
  @spec storage_error?(Exception.t()) :: boolean()
  def storage_error?(%DBConnection.ConnectionError{}), do: true
  def storage_error?(%DBConnection.OwnershipError{}), do: true

  # Only the Postgres errors listed in @temporary_sqlstate_classes and
  # @temporary_sqlstates may go away. Any other one (bad data, constraint violations,
  # invalid queries, program limits such as an index row that is too big...) fails
  # the same way on every delivery: redelivering the update would block its chat, or
  # every chat in polling mode.
  def storage_error?(%Postgrex.Error{
        postgres: %{pg_code: <<class::binary-size(2), _::binary>> = code}
      }),
      do: class in @temporary_sqlstate_classes or code in @temporary_sqlstates

  def storage_error?(%Postgrex.Error{}), do: true
  def storage_error?(_exception), do: false

  defp storage_failure(update, message) do
    message = "could not store update #{update_id(update)}: #{message}"
    Logger.error("Telegram: " <> message)
    {:error, message}
  end

  defp update_id(%{"update_id" => update_id}), do: update_id
  defp update_id(_update), do: "(without update_id)"

  ## Messages

  defp handle_message(update, type, message) do
    if ignored?(message) do
      {:ok, []}
    else
      settings = Settings.get()
      chat_id = message["chat"]["id"]

      cond do
        not Settings.chat_allowed?(settings, chat_id) ->
          Logger.debug("Ignoring Telegram message from chat #{chat_id}: not an allowed chat")
          {:ok, []}

        copy_of_channel_post?(message, settings) ->
          {:ok, []}

        true ->
          process_message(update, type, message, settings)
      end
    end
  end

  defp ignored?(
         %{"chat" => %{"id" => chat_id, "type" => type}, "message_id" => message_id} = message
       )
       when is_integer(chat_id) and is_binary(type) and is_integer(message_id) do
    sent_by_bot?(message) or text(message) == nil
  end

  defp ignored?(_message), do: true

  defp sent_by_bot?(message),
    do: get_in(message, ["from", "is_bot"]) == true and not is_map(message["sender_chat"])

  # A channel post Telegram forwarded to the channel's discussion group. When the bot
  # is not in the channel, the admin can still get replies to these by allowing only
  # the group.
  defp copy_of_channel_post?(
         %{"is_automatic_forward" => true, "sender_chat" => %{"id" => channel_id}},
         settings
       ),
       do: Settings.chat_allowed?(settings, channel_id)

  defp copy_of_channel_post?(_message, _settings), do: false

  defp text(message) do
    Enum.find_value(["text", "caption"], fn key ->
      if is_binary(message[key]), do: message[key]
    end)
  end

  defp process_message(update, type, message, settings) do
    urls = Links.extract(message)
    allowed = Enum.filter(urls, &Settings.host_allowed?(settings, Links.host(&1)))
    private_message? = type == "message" and message["chat"]["type"] == "private"
    command = command(message)

    cond do
      private_message? and command in ["start", "help"] ->
        reply(message, @help_text)
        {:ok, []}

      allowed != [] ->
        allowed
        |> Enum.map(&entry_attrs(update, message, &1))
        |> Entries.enqueue()

      private_message? and command == nil ->
        reply(message, hint(urls))
        {:ok, []}

      true ->
        {:ok, []}
    end
  end

  defp command(message) do
    case Regex.run(~r{\A/([A-Za-z0-9_]+)(?:@[A-Za-z0-9_]+)?(?:\s|\z)}, text(message)) do
      [_match, command] -> String.downcase(command)
      nil -> nil
    end
  end

  defp hint([]), do: @hint_text

  defp hint(urls) do
    hosts = urls |> Enum.map(&Links.host/1) |> Enum.uniq() |> Enum.join(", ")
    "Sorry, I don't download videos from #{hosts}."
  end

  defp entry_attrs(update, message, url) do
    chat = message["chat"]

    %{
      url: url,
      source_host: Links.host(url),
      update_id: update["update_id"],
      chat_id: chat["id"],
      chat_type: chat["type"],
      chat_title: chat_title(chat),
      message_id: message["message_id"],
      message_thread_id: topic_id(message),
      from_id: sender_id(message),
      from_name: sender_name(message),
      max_attempts: max_attempts()
    }
  end

  # In non-forum supergroups message_thread_id may be a reply thread, which
  # sendVideo rejects; only forum topics need it.
  defp topic_id(%{"is_topic_message" => true, "message_thread_id" => id}), do: id
  defp topic_id(_message), do: nil

  defp chat_title(chat), do: chat["title"] || full_name(chat) || username(chat)

  defp sender_id(%{"sender_chat" => %{"id" => id}}), do: id
  defp sender_id(%{"from" => %{"id" => id}}), do: id
  defp sender_id(_message), do: nil

  defp sender_name(%{"sender_chat" => sender_chat} = message) when is_map(sender_chat),
    do: message["author_signature"] || sender_chat["title"] || username(sender_chat)

  defp sender_name(%{"from" => from}) when is_map(from), do: username(from) || full_name(from)
  defp sender_name(_message), do: nil

  defp full_name(user_or_chat) do
    case Enum.reject([user_or_chat["first_name"], user_or_chat["last_name"]], &(&1 in [nil, ""])) do
      [] -> nil
      names -> Enum.join(names, " ")
    end
  end

  defp username(%{"username" => username}) when is_binary(username), do: "@" <> username
  defp username(_user_or_chat), do: nil

  defp max_attempts, do: Application.get_env(:angler, Angler.Pipeline, [])[:max_attempts] || 3

  defp reply(message, text) do
    chat_id = message["chat"]["id"]

    opts = [
      reply_to_message_id: message["message_id"],
      message_thread_id: topic_id(message),
      chat_type: message["chat"]["type"],
      link_preview: false
    ]

    Task.Supervisor.start_child(Angler.TaskSupervisor, fn ->
      case Telegram.send_message(chat_id, text, opts) do
        {:ok, _message} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "Could not reply in Telegram chat #{chat_id}: #{Exception.message(error)}"
          )
      end
    end)
  end

  ## Membership

  defp log_membership(%{
         "chat" => %{"id" => chat_id} = chat,
         "new_chat_member" => %{"status" => status}
       }) do
    chat_name = chat_title(chat) || "chat"
    Logger.info("Telegram: #{membership_change(chat["type"], status)} #{chat_name} (#{chat_id})")
  end

  defp log_membership(_change), do: :ok

  defp membership_change("private", "kicked"), do: "bot was blocked by"
  defp membership_change("private", "member"), do: "bot was started by"
  defp membership_change(_type, "kicked"), do: "bot was banned from"
  defp membership_change(_type, "left"), do: "bot was removed from"
  defp membership_change(_type, "member"), do: "bot was added to"
  defp membership_change(_type, status), do: "bot is now #{status} in"
end
