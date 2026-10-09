defmodule Angler.Pipeline.Feedback do
  @moduledoc """
  Best-effort feedback in the chat while an entry is processed: a 👀 reaction on
  the original message while working (set once when it can be sent right away,
  it stays while the entry is retried), cleared on success, 🤷 and (depending on
  `failure_replies`) a short reply on failure or when only part of an album could
  be sent, and an "uploading video" (or photo) chat action before an upload.
  Also sends the post text that is too long for a caption as a message of its own
  after the media (`follow_up/3`).

  Every call returns right away: the Bot API calls run in tasks under
  `Angler.TaskSupervisor`, so slow or rate limited requests never hold up a
  pipeline stage, and their failures (reactions may be disabled in a chat, the bot
  may lack rights) are only logged.
  """
  require Logger

  alias Angler.Entries.Entry
  alias Angler.Settings
  alias Angler.Settings.Setting
  alias Angler.Telegram

  @working "👀"
  @failed "🤷"
  # The follow-up text may wait behind the album it follows (one rate limiter
  # slot per item, and in groups 20 messages a minute).
  @follow_up_max_wait 120_000

  @doc """
  Reacts 👀 to the original message when reactions are enabled, but only when the
  reaction can be sent right away: one held back by the rate limiter (e.g. while
  the chat is backed off after a 429) could arrive together with, and after, the
  clear or 🤷 of an entry that finished meanwhile, and stay on the message.
  """
  @spec started(Entry.t(), Setting.t()) :: :ok
  def started(%Entry{} = entry, %Setting{reactions_enabled: true}),
    do: async(fn -> react(entry, @working, max_wait: 0) end)

  def started(%Entry{}, %Setting{}), do: :ok

  @doc "Clears the bot's reaction on the original message when reactions are enabled."
  @spec succeeded(Entry.t(), Setting.t()) :: :ok
  def succeeded(%Entry{} = entry, %Setting{reactions_enabled: true}),
    do: async(fn -> react(entry, nil) end)

  def succeeded(%Entry{}, %Setting{}), do: :ok

  @doc """
  For an upload Telegram never confirmed (the video may still appear): clears the
  bot's reaction like `succeeded/2`, without the 🤷 and reply of `failed/3`.
  """
  @spec unconfirmed(Entry.t(), Setting.t()) :: :ok
  def unconfirmed(%Entry{} = entry, %Setting{} = settings), do: succeeded(entry, settings)

  @doc """
  Shows `action` ("upload_video" or "upload_photo", i.e. "sending video" or
  "sending photo") in the chat while media is uploaded (not in channels, which
  don't support chat actions).
  """
  @spec uploading(Entry.t(), String.t()) :: :ok
  def uploading(entry, action \\ "upload_video")

  def uploading(%Entry{chat_type: "channel"}, _action), do: :ok

  def uploading(%Entry{} = entry, action) do
    async(fn ->
      entry.chat_id
      |> Telegram.send_chat_action(action,
        message_thread_id: entry.message_thread_id,
        chat_type: entry.chat_type
      )
      |> log_error(entry, "send the chat action")
    end)
  end

  @doc """
  Reacts 🤷 when reactions are enabled, and replies with `failure_text/2` when
  `failure_replies` is `:all`, or `:private` and the entry comes from a private chat.
  """
  @spec failed(Entry.t(), Entry.error_kind(), Setting.t()) :: :ok
  def failed(%Entry{} = entry, kind, %Setting{} = settings),
    do: failure_feedback(entry, failure_text(kind, settings), settings)

  @doc """
  For an album of which only `sent` of `total` items were sent, and the rest never
  will be: like `failed/3`, with `partial_text/2` as the reply.
  """
  @spec partial(Entry.t(), non_neg_integer(), non_neg_integer(), Setting.t()) :: :ok
  def partial(%Entry{} = entry, sent, total, %Setting{} = settings),
    do: failure_feedback(entry, partial_text(sent, total), settings)

  @doc "The reply sent to the chat when an entry failed with `kind`."
  @spec failure_text(Entry.error_kind(), Setting.t()) :: String.t()
  def failure_text(:unsupported, _settings), do: "I couldn't find anything to send at this link."

  def failure_text(:too_large, settings) do
    limit_mb = div(Settings.upload_limit_bytes(settings), 1_000_000)
    "This is too large or too long to send here (the limit is #{limit_mb} MB)."
  end

  def failure_text(:unavailable, _settings), do: "This post is private, removed or unavailable."
  def failure_text(:timeout, _settings), do: "Downloading this took too long."
  def failure_text(_kind, _settings), do: "Something went wrong while fetching this."

  @doc "The reply sent to the chat when only `sent` of an album's `total` items were sent."
  @spec partial_text(non_neg_integer(), non_neg_integer()) :: String.t()
  def partial_text(sent, total), do: "Only #{sent} of #{total} items could be sent."

  @doc """
  Sends `text`, the post text that didn't fit into the caption of media that is
  in the chat, as a message of its own replying to the message
  `reply_to_message_id` (the media), or to the original message when that is nil. Without
  notification, since the media just notified the chat. When the message to reply
  to is gone, the text is sent once more without replying.
  """
  @spec follow_up(Entry.t(), String.t(), integer() | nil) :: :ok
  def follow_up(%Entry{} = entry, text, reply_to_message_id) when is_binary(text) do
    async(fn ->
      entry
      |> send_follow_up(text, reply_to_message_id || entry.message_id)
      |> log_error(entry, "send the post text")
    end)
  end

  defp send_follow_up(entry, text, reply_to_message_id) do
    opts = [
      message_thread_id: entry.message_thread_id,
      chat_type: entry.chat_type,
      link_preview: false,
      disable_notification: true,
      max_wait: @follow_up_max_wait
    ]

    reply = [reply_to_message_id: reply_to_message_id]

    with {:error, error} = failed <- Telegram.send_message(entry.chat_id, text, reply ++ opts) do
      if Telegram.Error.kind(error) == :reply_not_found,
        do: Telegram.send_message(entry.chat_id, text, opts),
        else: failed
    end
  end

  defp failure_feedback(entry, text, settings) do
    react? = settings.reactions_enabled
    reply? = reply?(entry, settings.failure_replies)

    if react? or reply? do
      async(fn ->
        if react?, do: react(entry, @failed)
        if reply?, do: reply(entry, text)
      end)
    else
      :ok
    end
  end

  defp reply?(_entry, :all), do: true
  defp reply?(entry, :private), do: Entry.private_chat?(entry)
  defp reply?(_entry, _none), do: false

  defp react(entry, emoji, opts \\ []) do
    entry.chat_id
    |> Telegram.set_message_reaction(
      entry.message_id,
      emoji,
      Keyword.put(opts, :chat_type, entry.chat_type)
    )
    |> log_error(entry, "set the reaction")
  end

  defp reply(entry, text) do
    entry.chat_id
    |> Telegram.send_message(text,
      reply_to_message_id: entry.message_id,
      message_thread_id: entry.message_thread_id,
      chat_type: entry.chat_type,
      link_preview: false
    )
    |> log_error(entry, "send the failure reply")
  end

  defp log_error({:ok, _result}, _entry, _action), do: :ok

  defp log_error({:error, error}, entry, action) do
    Logger.info("Could not #{action} for entry #{entry.id}: #{Exception.message(error)}")
  end

  defp async(fun) do
    case Task.Supervisor.start_child(Angler.TaskSupervisor, fn -> run_safely(fun) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("Could not start a feedback task: #{inspect(reason)}")
    end

    :ok
  catch
    :exit, reason ->
      Logger.warning("Could not start a feedback task: #{Exception.format_exit(reason)}")
      :ok
  end

  defp run_safely(fun) do
    fun.()
  rescue
    exception ->
      Logger.warning(
        "Chat feedback failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )
  end
end
