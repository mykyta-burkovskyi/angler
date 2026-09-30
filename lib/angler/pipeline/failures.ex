defmodule Angler.Pipeline.Failures do
  @moduledoc """
  Handles the failed messages of both `Angler.Pipeline` stages (`handle_failed/2`):
  their entries are retried, postponed or failed for good according to
  `Angler.Pipeline.RetryPolicy`. Permanently failed entries lose their files and
  get failure feedback in the chat.

  An album of which a part was delivered (e.g. the upload crashed after its first
  part) is never retried, since that would post the part again: it fails for good
  as sent in part (`Angler.Pipeline.AlbumUpload.finish_partial/3`).

  Failures are reported with `Broadway.Message.failed/2` as `{kind, text}` or
  `{kind, text, retry_after_seconds}`, or come from a stage that raised.

  The entry is read again first and only handled while it is still in progress and
  held by the claim the message was made for: entries that were deleted, finished
  or claimed again meanwhile (e.g. by the producer's stale check) are left alone.
  When the database can't be reached, the handling is retried in the background
  until it can, instead of leaving the entry in progress.
  """
  require Logger

  alias Angler.{Entries, Settings, Storage}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{AlbumUpload, DbRetry, Feedback, RetryPolicy}
  alias Broadway.Message

  @expected_failures [:unsupported, :unavailable, :too_large]

  @doc """
  Retries or fails the entry of a failed message. Never raises.

  `context` may contain `:retry_base_delay` (see `Angler.Pipeline.RetryPolicy.decide/4`)
  and `:db_retry_delays` (ms between background attempts while the database can't
  be reached).
  """
  @spec handle(Message.t(), map()) :: :ok
  def handle(%Message{} = message, context) do
    handle_now(message, context)
  rescue
    exception in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "Could not handle a failed entry, trying again in the background: " <>
          Exception.message(exception)
      )

      handle_later(message, context)

    exception ->
      log_error(:error, exception, __STACKTRACE__)
  catch
    kind, reason -> log_error(kind, reason, __STACKTRACE__)
  end

  defp handle_now(message, context) do
    claimed = claimed_entry(message.data)

    with %Entry{} = entry <- Entries.get(claimed.id),
         true <- Entry.active?(entry) and same_claim?(entry, claimed) do
      {kind, text, retry_after} = RetryPolicy.classify(message.status)

      if AlbumUpload.partly_delivered?(entry) do
        AlbumUpload.finish_partial(entry, Settings.get(), text)
      else
        case RetryPolicy.decide(entry, kind, retry_after, decide_opts(context)) do
          {:retry, delay} -> retry(entry, kind, text, delay, [])
          {:postpone, delay} -> retry(entry, kind, text, delay, count_attempt: false)
          :fail -> fail(entry, kind, text)
        end
      end
    end

    :ok
  end

  defp handle_later(message, context) do
    delays = Map.get(context, :db_retry_delays, DbRetry.background_delays())

    DbRetry.async(fn ->
      case DbRetry.run(fn -> handle_now(message, context) end, delays) do
        {:ok, :ok} ->
          :ok

        {:error, exception} ->
          Logger.error("Gave up handling a failed entry: " <> Exception.message(exception))
      end
    end)
  end

  defp log_error(kind, reason, stacktrace) do
    Logger.error(
      "Could not handle a failed entry: " <> Exception.format(kind, reason, stacktrace)
    )

    :ok
  end

  defp claimed_entry(%Entry{} = entry), do: entry
  defp claimed_entry(%{entry: %Entry{} = entry}), do: entry

  defp same_claim?(%Entry{claimed_at: %DateTime{} = current}, %Entry{
         claimed_at: %DateTime{} = own
       }),
       do: DateTime.compare(current, own) == :eq

  defp same_claim?(_entry, _claimed), do: false

  defp decide_opts(context) do
    case Map.get(context, :retry_base_delay) do
      nil -> []
      base_delay -> [base_delay: base_delay]
    end
  end

  defp retry(entry, kind, text, delay, opts) do
    Logger.info(
      "Entry #{entry.id} failed (#{kind}, attempt #{entry.attempts} of #{entry.max_attempts}), " <>
        "#{if opts == [], do: "retrying", else: "postponed"} in #{delay} ms: #{text}"
    )

    Entries.schedule_retry(entry, kind, text, delay, opts)
  end

  defp fail(entry, kind, text) do
    level = if kind in @expected_failures, do: :info, else: :warning
    Logger.log(level, "Entry #{entry.id} (#{entry.url}) failed (#{kind}): #{text}")

    entry = Entries.mark_failed(entry, kind, text)
    Feedback.failed(entry, kind, Settings.get())
    Storage.purge(entry)
  end
end
