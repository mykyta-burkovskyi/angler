@AGENTS.md

# Angler

A self-hosted Telegram bot: people post links (TikTok, Instagram, YouTube, X, ...)
in a chat, Angler downloads the video with yt-dlp, makes it fit Telegram's upload
limit with ffmpeg when needed, and replies to the message with the video. A Phoenix
LiveView dashboard shows every processing entry live and lets the admin adjust
storage limits and filters. Deployed with docker compose (app + Postgres, optional
local Bot API server).

## Architecture

```
Telegram ──webhook──▶ TelegramWebhookController ─▶ Telegram.Updates.handle/1
          (or Telegram.Receiver polling in dev)       │ extract links, filter
                                                      ▼
                                       Entries.enqueue/1 (Postgres "entries" row, status queued)
                                                      │ PubSub "entries:queue"
                                                      ▼
Pipeline (Broadway) ── Producer: Entries.claim/1 (FOR UPDATE SKIP LOCKED)
   processors (DOWNLOAD_CONCURRENCY): Media.download → Media.prepare (ffmpeg) → Storage
   batcher :telegram (UPLOAD_CONCURRENCY): Telegram.send_video (RateLimiter) → Entries.mark_done
   ack/failure: retry with backoff (Entries.schedule_retry) or Entries.mark_failed
                                                      │ PubSub "entries"
                                                      ▼
                             Dashboard LiveViews (EntriesLive, EntryLive, SettingsLive)
Storage.Janitor: retention + size cap eviction of kept media (Settings)
```

- `Angler.Entries` is the only module that writes `entries`; it broadcasts every change.
  The table is also the durable job queue: a crash or restart never loses work
  (`Entries.recover_orphaned/0` re-queues in-flight entries at boot).
- `Angler.Settings` holds dashboard-adjustable settings (single DB row, read per use).
  Deployment settings (tokens, concurrency, paths) come from env vars in `config/runtime.exs`.
- External tools run through `Angler.Media.Command` (bounded runtime, killed with their
  process group on timeout or caller exit, `:on_tick` for watching running programs) and
  never inherit secrets (env vars matching TOKEN/SECRET/PASSWORD/COOKIE/DATABASE_URL/...
  are stripped). yt-dlp traffic goes through `Angler.Media.EgressProxy`, which refuses
  private/loopback/link-local addresses unless `ALLOW_PRIVATE_NETWORK_DOWNLOADS=true`.
- TikTok photo slideshows are fetched directly (`Angler.Media.TikTok`) and assembled with
  ffmpeg (`Angler.Media.Slideshow`); regular TikTok videos still go through yt-dlp.
- External tools are wrapped behind `Angler.Media` (a behaviour, swappable in tests)
  and HTTP calls to Telegram go through `Angler.Telegram` (Req; tests stub it with
  `Req.Test` under the name `Angler.Telegram`).
- Sizes use decimal megabytes (1 MB = 1,000,000 bytes). The cloud Bot API accepts
  uploads up to 50 MB; a local Bot API server (`TELEGRAM_LOCAL_MODE=true`) up to 2000 MB.

## Conventions

- Contexts return `{:ok, _} | {:error, _}`; internal, trusted updates use
  `Entries.update!/2` (no casting). Never write to `entries` with `Repo` directly
  outside `Angler.Entries` (storage accounting in `Angler.Storage` is the exception
  and must broadcast through `Entries.update!/2`).
- Error kinds (`Angler.Entries.Entry.error_kinds/0`) drive retries: `:transient`,
  `:timeout` and `:internal` are retried automatically (up to `max_attempts`);
  `:unsupported`, `:too_large`, `:unavailable` and `:telegram` fail immediately.
- Anything that spawns OS processes must bound their runtime and kill them on
  timeout (see `Angler.Media.Command`).
- Env vars are read only in `config/runtime.exs`, through its `bool_env`/`url_env`/
  `int_env` helpers, so a bad value stops the boot with an error naming the variable
  (`test/angler/runtime_config_test.exs` evaluates the file as a prod release would).
  Document new variables in `.env.example` and the README configuration reference.
- `File.stream!/2` must be given a chunk size (e.g. `File.stream!(path, 65_536)`) for
  binary files: the default `:line` mode normalizes CRLF and corrupts videos.
- Tests: `mix test` needs Postgres on localhost:5432 (user/password `postgres`).
  Tests tagged `:external` need ffmpeg/ffprobe/yt-dlp and are excluded unless those
  binaries exist; tests tagged `:network` reach the internet and only run with
  `mix test --include network`. Keep tests async where they don't touch global processes.
- Keep modules focused: split a file when it mixes responsibilities or has more than
  ~250 lines of code (excluding docs/specs), aiming for most files under ~200 lines.
  Contexts stay the public entry point and `defdelegate` to focused internal modules
  (e.g. `Angler.Entries` -> `Angler.Entries.Queue`). `core_components.ex` stays one file.
- Run `mix precommit` before finishing a change.
