defmodule Angler.Pipeline.RetryPolicy do
  @moduledoc """
  Pure decisions about failed entries: which error kind a failure has, and whether
  (and when) the entry is retried.

  Failures travel through Broadway as message statuses:

    * `{:failed, {kind, text}}` and `{:failed, {kind, text, retry_after_seconds}}` -
      set by the pipeline steps with `Broadway.Message.failed/2` (see
      `media_failure/1`, `storage_failure/1` and `telegram_failure/2`)
    * `{kind, reason, stacktrace}` - set by Broadway when a callback raised, threw or
      exited; these are bugs or crashes and are classified as `:internal`

  `:transient`, `:timeout` and `:internal` failures are retried while the entry has
  attempts left, after an exponential backoff of `base_delay * 4^(attempts - 1)`
  (30 s, 2 min, 8 min, ... by default, capped at one hour) with ±20% jitter.

  Failures that say when to try again (`retry_after`: a Telegram 429 or a send held
  back by the local rate limiter, a cached file Telegram no longer accepts) are
  postponed instead: the entry is retried after `retry_after` seconds and the
  attempt is not counted, since nothing was wrong with the video. Postponing stops
  24 hours after the entry was first claimed, so a chat that keeps answering 429
  can't hold an entry forever; from then on these failures use up attempts like
  others.

  Low free disk space postpones the entry without that limit, until space is freed:
  its `retry_after` is `{:always, seconds}` (see `storage_failure/1`).
  """
  alias Angler.Entries.Entry
  alias Angler.Media
  alias Angler.Telegram.Error, as: TelegramError

  @type kind :: Entry.error_kind()
  @typedoc "Seconds to wait; `{:always, seconds}` postpones without the 24-hour limit."
  @type retry_after :: non_neg_integer() | {:always, non_neg_integer()}
  @type failure :: {kind(), String.t()} | {kind(), String.t(), retry_after()}
  @type classified :: {kind(), String.t(), retry_after() | nil}
  @type decision ::
          {:retry, delay_ms :: non_neg_integer()}
          | {:postpone, delay_ms :: non_neg_integer()}
          | :fail

  @retryable [:transient, :timeout, :internal]
  @default_base_delay 30_000
  @max_backoff :timer.hours(1)
  @jitter 0.2
  @postpone_window :timer.hours(24)
  @low_disk_space_delay 300
  @unconfirmed_text "Telegram did not confirm the upload in time; the video may still appear in the chat"

  @doc "Whether failures of this kind are retried automatically."
  @spec retryable?(kind()) :: boolean()
  def retryable?(kind), do: kind in @retryable

  @doc """
  Turns a failed `Broadway.Message` status into `{kind, text, retry_after_seconds}`.
  Unknown kinds and crashes become `:internal`.
  """
  @spec classify(term()) :: classified()
  def classify({:failed, {kind, text}}), do: classify({:failed, {kind, text, nil}})

  def classify({:failed, {kind, text, retry_after}}),
    do: {normalize_kind(kind), to_text(text), normalize_retry_after(retry_after)}

  def classify({:failed, reason}), do: {:internal, to_text(reason), nil}

  def classify({kind, reason, stacktrace}) when kind in [:error, :exit, :throw],
    do: {:internal, Exception.format_banner(kind, reason, stacktrace), nil}

  def classify(status), do: {:internal, "Unexpected failure: " <> inspect(status), nil}

  @doc """
  Decides what happens to an entry whose current attempt failed with `kind`:
  `{:retry, delay_ms}` (the attempt counts), `{:postpone, delay_ms}` (the attempt
  is given back, see the moduledoc) or `:fail`.

  `entry` needs `:attempts` (already incremented for the failed attempt),
  `:max_attempts` and `:started_at` (when it was first claimed, may be nil).
  Options: `:base_delay` (ms, default #{@default_base_delay}), `:random` (a float in
  `0..1` used for the jitter, random by default) and `:now` (a `DateTime`).
  """
  @spec decide(map(), kind(), retry_after() | nil, keyword()) :: decision()
  def decide(entry, kind, retry_after, opts \\ [])

  def decide(_entry, kind, {:always, seconds}, _opts) do
    if retryable?(kind), do: {:postpone, seconds * 1_000}, else: :fail
  end

  def decide(%{attempts: attempts, max_attempts: max_attempts} = entry, kind, retry_after, opts) do
    cond do
      not retryable?(kind) -> :fail
      is_integer(retry_after) and postponable?(entry, opts) -> {:postpone, retry_after * 1_000}
      attempts < max_attempts -> {:retry, delay(attempts, retry_after, opts)}
      true -> :fail
    end
  end

  defp postponable?(entry, opts) do
    case Map.get(entry, :started_at) do
      %DateTime{} = started_at ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        DateTime.diff(now, started_at, :millisecond) < @postpone_window

      nil ->
        true
    end
  end

  @doc """
  Milliseconds to wait before the next attempt: `retry_after` seconds when given,
  else the jittered exponential backoff (see `backoff/3`).
  """
  @spec delay(non_neg_integer(), non_neg_integer() | nil, keyword()) :: non_neg_integer()
  def delay(_attempts, retry_after, _opts) when is_integer(retry_after) and retry_after >= 0,
    do: retry_after * 1_000

  def delay(attempts, _retry_after, opts) do
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    random = Keyword.get_lazy(opts, :random, &:rand.uniform/0)
    backoff(attempts, base_delay, random)
  end

  @doc """
  `base_delay * 4^(attempts - 1)` (at most one hour), scaled by a factor between
  0.8 (`random` = 0) and 1.2 (`random` = 1).
  """
  @spec backoff(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  def backoff(attempts, base_delay, random) when random >= 0 and random <= 1 do
    delay = min(base_delay * 4 ** (max(attempts, 1) - 1), @max_backoff)
    round(delay * (1 - @jitter + 2 * @jitter * random))
  end

  @doc """
  The failure when the entry's media directory can't be prepared
  (`Angler.Storage.prepare_dir/1`): too little free disk space postpones the
  entry by #{div(@low_disk_space_delay, 60)} minutes at a time for as long as it
  lasts, without using attempts; anything else is internal.
  """
  @spec storage_failure(term()) :: failure()
  def storage_failure(:low_disk_space),
    do: {:transient, "Not enough free disk space", {:always, @low_disk_space_delay}}

  def storage_failure(reason),
    do: {:internal, "Could not prepare the media directory: #{inspect(reason)}"}

  @doc "The failure for a `Angler.Media` error."
  @spec media_failure(Media.Error.t()) :: failure()
  def media_failure(%Media.Error{kind: kind, message: message}),
    do: {normalize_kind(kind), to_text(message || "Media processing failed")}

  @doc """
  The failure for a failed `sendVideo`. `reused_file_id?` tells whether the video
  was sent by the `file_id` of an earlier delivery: when Telegram rejects that
  file, the entry is postponed by 0 seconds (and downloads the video again).

  A request that was sent but never answered (`:unconfirmed`) may still have
  posted the video, so it fails for good instead of being sent twice.
  """
  @spec telegram_failure(TelegramError.t(), boolean()) :: failure()
  def telegram_failure(%TelegramError{} = error, reused_file_id?) do
    text = Exception.message(error)

    case TelegramError.kind(error) do
      :invalid_file when reused_file_id? ->
        {:transient, "Telegram no longer accepts the cached file, downloading again: " <> text, 0}

      :rate_limited when is_integer(error.retry_after) ->
        {:transient, text, error.retry_after}

      :unconfirmed ->
        {:telegram, unconfirmed_text()}

      :network when error.reason == :enoent ->
        {:internal, text}

      kind when kind in [:network, :server_error, :rate_limited] ->
        {:transient, text}

      :too_large ->
        {:too_large, text}

      _other ->
        {:telegram, text}
    end
  end

  @doc "What an entry whose upload Telegram never confirmed fails with."
  @spec unconfirmed_text() :: String.t()
  def unconfirmed_text, do: @unconfirmed_text

  defp normalize_kind(kind) do
    if kind in Entry.error_kinds(), do: kind, else: :internal
  end

  defp normalize_retry_after({:always, seconds}) do
    case normalize_retry_after(seconds) do
      nil -> nil
      seconds -> {:always, seconds}
    end
  end

  defp normalize_retry_after(seconds) when is_integer(seconds) and seconds >= 0, do: seconds
  defp normalize_retry_after(seconds) when is_float(seconds) and seconds >= 0, do: ceil(seconds)
  defp normalize_retry_after(_seconds), do: nil

  defp to_text(text) when is_binary(text), do: text
  defp to_text(exception) when is_exception(exception), do: Exception.message(exception)
  defp to_text(other), do: inspect(other)
end
