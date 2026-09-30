@AGENTS.md

# Angler

A self-hosted Telegram bot: people post links (TikTok, Instagram, YouTube, X, ...)
in a chat, Angler downloads the video with yt-dlp (or an Instagram post's photos and
videos), makes it fit Telegram's upload limit with ffmpeg when needed, and replies to
the message with the video (or an album). A Phoenix LiveView dashboard shows every
processing entry live and lets the admin adjust storage limits and filters. Deployed
with docker compose (app + Postgres, optional local Bot API server).

## Architecture

```
Telegram ──webhook──▶ TelegramWebhookController ─▶ Telegram.Updates.handle/1
          (or Telegram.Receiver polling in dev)       │ extract links, filter
                                                      ▼
                                       Entries.enqueue/1 (Postgres "entries" row, status queued)
                                                      │ PubSub "entries:queue"
                                                      ▼
Pipeline (Broadway) ── Producer: Entries.claim/1 (FOR UPDATE SKIP LOCKED)
   processors (DOWNLOAD_CONCURRENCY): Media.download (Media.Route) → Media.prepare (ffmpeg) → Storage
   batcher :telegram (UPLOAD_CONCURRENCY): Upload (send_video) | AlbumUpload (send_media_group,
      send_photo; RateLimiter) → Entries.mark_done
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
- `Angler.Media.Route` picks how a link is fetched: Instagram posts first
  (`Angler.Media.Instagram.route/3`), then TikTok (`Angler.Media.TikTok.route/1`), else yt-dlp.
- TikTok photo slideshows are fetched directly (`Angler.Media.TikTok`) and assembled with
  ffmpeg (`Angler.Media.Slideshow`); regular TikTok videos still go through yt-dlp.
- Instagram posts are read logged out, without cookies: `Instagram.Url` (share links
  resolved with one request) → `Instagram.GraphQL` → `Instagram.Page` → `Ytdlp.metadata/3`
  (the only step with cookies). Photos or several items become an album
  (`Angler.Media.Album`: CDN-only `Angler.Media.Fetch` with a shared byte budget, photos
  checked by `Album.Photo`, videos through `Media.Prepare`, files at
  `<entry dir>/album/NN/`); a single video (reel) goes to yt-dlp with the post text as title.
- Albums: `Entry.media_kind == :album`, items in `entries.media_items`
  (`Angler.Entries.MediaItem`, paths relative to the entry dir, validated by
  `Angler.Storage.Album` before any use). `Angler.Pipeline.AlbumUpload` sends them in parts
  of up to 10 (`AlbumUpload.Plan`), records file ids after each part and never re-sends a
  delivered part (a partly delivered album fails as partial). Albums are never re-used by
  file id. Post text over 1024 UTF-16 units follows as a message once the media was delivered
  (`Pipeline.Caption.split/3`); never on its own after an unconfirmed upload, so in local mode
  the media also gets it cut to 1024 (`Pipeline.Delivery.caption/1`).
- Cookies (`YTDLP_COOKIES_FILE`, `Angler.Media.Cookies`) are a fallback: yt-dlp always gets a
  private copy (`Angler.Media.Ytdlp.Runner`, shared by downloads and metadata runs);
  TikTok post pages load once more with them when hidden or unreadable. Requests carrying
  cookies never follow redirects and never log transport error messages.
- External tools are wrapped behind `Angler.Media` (a behaviour, swappable in tests)
  and HTTP calls to Telegram go through `Angler.Telegram` (Req; tests stub it with
  `Req.Test` under the name `Angler.Telegram`; likewise `Angler.Media.TikTok` and
  `Angler.Media.Instagram` for TikTok/Instagram and their CDNs).
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
