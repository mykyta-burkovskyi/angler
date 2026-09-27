defmodule Angler.Pipeline.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Angler.Entries.Entry
  alias Angler.Media
  alias Angler.Pipeline.RetryPolicy
  alias Angler.Telegram.Error, as: TelegramError

  describe "retryable?/1" do
    test "only transient, timeout and internal failures are retried" do
      assert Enum.filter(Entry.error_kinds(), &RetryPolicy.retryable?/1) ==
               [:transient, :timeout, :internal]
    end
  end

  describe "classify/1" do
    test "keeps the kind and text given to Message.failed/2" do
      for kind <- Entry.error_kinds() do
        assert RetryPolicy.classify({:failed, {kind, "boom"}}) == {kind, "boom", nil}
      end
    end

    test "keeps retry_after seconds" do
      assert RetryPolicy.classify({:failed, {:transient, "429", 7}}) == {:transient, "429", 7}
      assert RetryPolicy.classify({:failed, {:transient, "429", 0}}) == {:transient, "429", 0}
      assert RetryPolicy.classify({:failed, {:transient, "429", 1.2}}) == {:transient, "429", 2}
      assert RetryPolicy.classify({:failed, {:transient, "429", nil}}) == {:transient, "429", nil}
      assert RetryPolicy.classify({:failed, {:transient, "429", -1}}) == {:transient, "429", nil}

      assert RetryPolicy.classify({:failed, {:transient, "disk", {:always, 1.2}}}) ==
               {:transient, "disk", {:always, 2}}

      assert RetryPolicy.classify({:failed, {:transient, "disk", {:always, -1}}}) ==
               {:transient, "disk", nil}
    end

    test "turns unknown kinds and non-string texts into internal failures" do
      assert RetryPolicy.classify({:failed, {:bogus, "text"}}) == {:internal, "text", nil}

      assert RetryPolicy.classify({:failed, {:unsupported, :oops}}) ==
               {:unsupported, ":oops", nil}

      assert RetryPolicy.classify({:failed, {:timeout, %RuntimeError{message: "slow"}}}) ==
               {:timeout, "slow", nil}
    end

    test "treats other failure reasons as internal" do
      assert RetryPolicy.classify({:failed, "plain reason"}) == {:internal, "plain reason", nil}
      assert RetryPolicy.classify({:failed, :oops}) == {:internal, ":oops", nil}
    end

    test "classifies raises, exits and throws as internal with a readable text" do
      assert RetryPolicy.classify({:error, %RuntimeError{message: "boom"}, []}) ==
               {:internal, "** (RuntimeError) boom", nil}

      assert RetryPolicy.classify({:exit, :killed, []}) == {:internal, "** (exit) killed", nil}
      assert RetryPolicy.classify({:throw, :ball, []}) == {:internal, "** (throw) :ball", nil}
    end

    test "classifies anything else as internal" do
      assert {:internal, "Unexpected failure: :ok", nil} = RetryPolicy.classify(:ok)
    end
  end

  describe "decide/4" do
    test "retries retryable kinds while attempts are left" do
      for kind <- [:transient, :timeout, :internal], attempts <- 1..2 do
        assert {:retry, delay} =
                 RetryPolicy.decide(entry(attempts, 3), kind, nil, base_delay: 1_000, random: 0.5)

        assert delay == 1_000 * 4 ** (attempts - 1)
      end
    end

    test "fails retryable kinds on the last attempt" do
      for kind <- [:transient, :timeout, :internal] do
        assert RetryPolicy.decide(entry(3, 3), kind, nil) == :fail
        assert RetryPolicy.decide(entry(4, 3), kind, nil) == :fail
        assert RetryPolicy.decide(entry(1, 1), kind, nil) == :fail
      end
    end

    test "never retries permanent kinds" do
      for kind <- [:unsupported, :too_large, :unavailable, :telegram] do
        assert RetryPolicy.decide(entry(1, 3), kind, nil) == :fail
        assert RetryPolicy.decide(entry(1, 3), kind, 5) == :fail
      end
    end

    test "postpones by retry_after seconds when given, even on the last attempt" do
      assert RetryPolicy.decide(entry(1, 3), :transient, 42) == {:postpone, 42_000}
      assert RetryPolicy.decide(entry(2, 3), :transient, 0) == {:postpone, 0}
      assert RetryPolicy.decide(entry(3, 3), :transient, 3_600) == {:postpone, 3_600_000}
      assert RetryPolicy.decide(entry(1, 1), :internal, 300) == {:postpone, 300_000}
    end

    test "stops postponing 24 hours after the entry was first claimed" do
      now = ~U[2026-01-02 12:00:00Z]
      recent = %{entry(3, 3) | started_at: DateTime.add(now, -23, :hour)}
      old = %{entry(3, 3) | started_at: DateTime.add(now, -24, :hour)}

      assert RetryPolicy.decide(recent, :transient, 5, now: now) == {:postpone, 5_000}
      assert RetryPolicy.decide(old, :transient, 5, now: now) == :fail

      # Attempts left: an ordinary retry after retry_after seconds.
      assert RetryPolicy.decide(%{old | attempts: 1}, :transient, 5, now: now) == {:retry, 5_000}
    end

    test "never postpones permanent kinds" do
      assert RetryPolicy.decide(entry(1, 3), :telegram, 5) == :fail
    end

    test "uses a jittered backoff of 30 s, 2 min, 8 min by default" do
      for {attempts, expected} <- [{1, 30_000}, {2, 120_000}, {3, 480_000}] do
        for _ <- 1..50 do
          assert {:retry, delay} = RetryPolicy.decide(entry(attempts, 10), :internal, nil)
          assert delay >= expected * 0.8 and delay <= expected * 1.2
        end
      end
    end
  end

  describe "backoff/3" do
    test "grows 4x per attempt" do
      assert RetryPolicy.backoff(1, 30_000, 0.5) == 30_000
      assert RetryPolicy.backoff(2, 30_000, 0.5) == 120_000
      assert RetryPolicy.backoff(3, 30_000, 0.5) == 480_000
      assert RetryPolicy.backoff(2, 10, 0.5) == 40
    end

    test "applies ±20% jitter" do
      assert RetryPolicy.backoff(1, 30_000, 0.0) == 24_000
      assert RetryPolicy.backoff(1, 30_000, 1.0) == 36_000
      assert RetryPolicy.backoff(1, 30_000, 0.25) == 27_000
    end

    test "treats attempt 0 like the first attempt" do
      assert RetryPolicy.backoff(0, 30_000, 0.5) == 30_000
    end

    test "is capped at one hour before jitter" do
      assert RetryPolicy.backoff(5, 30_000, 0.5) == 3_600_000
      assert RetryPolicy.backoff(40, 30_000, 1.0) == 4_320_000
    end
  end

  describe "storage_failure/1" do
    test "postpones the entry by 5 minutes when free disk space is low, for as long as it lasts" do
      assert {:transient, "Not enough free disk space", retry_after} =
               failure = RetryPolicy.storage_failure(:low_disk_space)

      assert RetryPolicy.classify({:failed, failure}) == failure
      assert RetryPolicy.decide(entry(3, 3), :transient, retry_after) == {:postpone, 300_000}

      # Unlike other postponed failures, also long after the first claim.
      now = ~U[2026-01-02 12:00:00Z]
      old = %{entry(3, 3) | started_at: DateTime.add(now, -30, :day)}
      assert RetryPolicy.decide(old, :transient, retry_after, now: now) == {:postpone, 300_000}
    end

    test "treats other errors as internal" do
      assert RetryPolicy.storage_failure(:eacces) ==
               {:internal, "Could not prepare the media directory: :eacces"}
    end
  end

  describe "media_failure/1" do
    test "keeps the kind and message of the media error" do
      for kind <- Entry.error_kinds() do
        assert RetryPolicy.media_failure(Media.Error.new(kind, "why")) == {kind, "why"}
      end
    end

    test "falls back to internal and a generic message" do
      assert RetryPolicy.media_failure(Media.Error.new(:weird, "why")) == {:internal, "why"}

      assert RetryPolicy.media_failure(Media.Error.new(:transient, nil)) ==
               {:transient, "Media processing failed"}
    end
  end

  describe "telegram_failure/2" do
    test "retries 429 after retry_after" do
      error = %TelegramError{
        method: "sendVideo",
        code: 429,
        description: "Too Many Requests",
        retry_after: 12
      }

      assert RetryPolicy.telegram_failure(error, false) ==
               {:transient, "Telegram sendVideo failed (429): Too Many Requests", 12}

      assert {:transient, _text} =
               RetryPolicy.telegram_failure(%TelegramError{error | retry_after: nil}, false)
    end

    test "retries network and server errors" do
      network = %TelegramError{
        method: "sendVideo",
        description: "timeout",
        reason: %RuntimeError{}
      }

      assert {:transient, "Telegram sendVideo failed: timeout"} =
               RetryPolicy.telegram_failure(network, false)

      assert {:transient, _text} =
               RetryPolicy.telegram_failure(%TelegramError{network | request_sent: false}, true)

      for code <- [500, 502, 504] do
        error = %TelegramError{method: "sendVideo", code: code, description: "Bad Gateway"}
        assert {:transient, _text} = RetryPolicy.telegram_failure(error, false)
      end
    end

    test "fails uploads Telegram may have received but never confirmed" do
      for reason <- [:timeout, :closed], reused_file_id? <- [false, true] do
        error = %TelegramError{
          method: "sendVideo",
          description: "#{reason}",
          reason: %Req.TransportError{reason: reason},
          request_sent: true
        }

        assert RetryPolicy.telegram_failure(error, reused_file_id?) ==
                 {:telegram,
                  "Telegram did not confirm the upload in time; the video may still appear in the chat"}
      end
    end

    test "treats a missing video file as internal" do
      error = %TelegramError{
        method: "sendVideo",
        description: "video file not found",
        reason: :enoent
      }

      assert {:internal, _text} = RetryPolicy.telegram_failure(error, false)
    end

    test "fails oversized uploads as too large" do
      for error <- [
            %TelegramError{method: "sendVideo", code: 413, description: "HTTP 413"},
            %TelegramError{
              method: "sendVideo",
              code: 400,
              description: "Bad Request: file is too big"
            }
          ] do
        assert {:too_large, _text} = RetryPolicy.telegram_failure(error, false)
      end
    end

    test "fails other client errors permanently" do
      for {code, description} <- [
            {403, "Forbidden: bot was blocked by the user"},
            {403, "Forbidden: bot was kicked from the supergroup chat"},
            {400, "Bad Request: chat not found"},
            {400, "Bad Request: message thread not found"},
            {401, "Unauthorized"},
            {400, "Bad Request: wrong file identifier/HTTP URL specified"}
          ] do
        error = %TelegramError{method: "sendVideo", code: code, description: description}
        assert {:telegram, text} = RetryPolicy.telegram_failure(error, false)
        assert text =~ description
      end
    end

    test "asks for an immediate retry when a re-used file_id was rejected" do
      for description <- [
            "Bad Request: wrong file identifier/HTTP URL specified",
            "Bad Request: FILE_ID_INVALID",
            "Bad Request: file reference expired"
          ] do
        error = %TelegramError{method: "sendVideo", code: 400, description: description}
        assert {:transient, text, 0} = RetryPolicy.telegram_failure(error, true)
        assert text =~ "downloading again"
        assert text =~ description
      end
    end

    test "fails other errors of re-used files like any upload" do
      error = %TelegramError{
        method: "sendVideo",
        code: 403,
        description: "Forbidden: bot was blocked by the user"
      }

      assert {:telegram, _text} = RetryPolicy.telegram_failure(error, true)
    end
  end

  defp entry(attempts, max_attempts), do: %Entry{attempts: attempts, max_attempts: max_attempts}
end
