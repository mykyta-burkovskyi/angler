defmodule Angler.Pipeline.Feedback do
  @moduledoc """
  Best-effort feedback in the chat while an entry is processed: a 👀 reaction on
  the original message while working (set once when it can be sent right away,
  it stays while the entry is retried), cleared on success, 👎 and (depending on
  `failure_replies`) a short reply on failure, and an "uploading video" chat action
  before an upload.

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
  @failed "👎"

  @doc """
  Reacts 👀 to the original message when reactions are enabled, but only when the
  reaction can be sent right away: one held back by the rate limiter (e.g. while
  the chat is backed off after a 429) could arrive together with, and after, the
  clear or 👎 of an entry that finished meanwhile, and stay on the message.
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
  bot's reaction like `succeeded/2`, without the 👎 and reply of `failed/3`.
  """
  @spec unconfirmed(Entry.t(), Setting.t()) :: :ok
  def unconfirmed(%Entry{} = entry, %Setting{} = settings), do: succeeded(entry, settings)

  @doc """
  Shows "sending video" in the chat while a video is uploaded (not in channels,
  which don't support chat actions).
  """
  @spec uploading(Entry.t()) :: :ok
  def uploading(%Entry{chat_type: "channel"}), do: :ok

  def uploading(%Entry{} = entry) do
    async(fn ->
      entry.chat_id
      |> Telegram.send_chat_action("upload_video",
        message_thread_id: entry.message_thread_id,
        chat_type: entry.chat_type
      )
      |> log_error(entry, "send the chat action")
    end)
  end

  @doc """
  Reacts 👎 when reactions are enabled, and replies with `failure_text/2` when
  `failure_replies` is `:all`, or `:private` and the entry comes from a private chat.
  """
  @spec failed(Entry.t(), Entry.error_kind(), Setting.t()) :: :ok
  def failed(%Entry{} = entry, kind, %Setting{} = settings) do
    react? = settings.reactions_enabled
    reply? = reply?(entry, settings.failure_replies)

    if react? or reply? do
      text = failure_text(kind, settings)

      async(fn ->
        if react?, do: react(entry, @failed)
        if reply?, do: reply(entry, text)
      end)
    else
      :ok
    end
  end

  @doc "The reply sent to the chat when an entry failed with `kind`."
  @spec failure_text(Entry.error_kind(), Setting.t()) :: String.t()
  def failure_text(:unsupported, _settings), do: "I couldn't find a video at this link."

  def failure_text(:too_large, settings) do
    limit_mb = div(Settings.upload_limit_bytes(settings), 1_000_000)
    "This video is too large or too long to send here (the limit is #{limit_mb} MB)."
  end

  def failure_text(:unavailable, _settings), do: "This video is private, removed or unavailable."
  def failure_text(:timeout, _settings), do: "Downloading this video took too long."
  def failure_text(_kind, _settings), do: "Something went wrong while fetching this video."

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
