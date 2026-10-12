@AGENTS.md

# Angler

A self-hosted Telegram bot: people post links (TikTok, Instagram, Threads, YouTube,
X, ...) in a chat, Angler downloads the video with yt-dlp (or an Instagram or Threads
post's photos and videos), makes it fit Telegram's upload limit with ffmpeg when needed, and replies to
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
  (`Angler.Media.Instagram.route/3`: album, slideshow or yt-dlp), then Threads
  (`Angler.Media.Threads.route/1`: video, album or slideshow), then TikTok
  (`Angler.Media.TikTok.route/1`), else yt-dlp.
- Photo posts with a sound become one video (`Angler.Media.Slideshow`, assembled with
  ffmpeg by `Slideshow.Render`). TikTok photo posts are fetched directly
  (`Angler.Media.TikTok`). Instagram photo posts with music (`Slideshow.Instagram`) reuse
  `Album.download/3` for the photos, and `Slideshow.Sound` fetches the song from the CDN
  and cuts the post's clip into `album/sound/clip.flac` (`Slideshow.Clip`), so Render
  loops the clip, not the song; a clip that is the whole song keeps the downloaded
  `album/sound/audio.m4a` (or `.mp3`). An Instagram post whose song can't be fetched or
  used on the final attempt (refused, network trouble, not audio, can't be cut, an
  ffprobe/ffmpeg timeout) goes out as an album, never as a silent video; a missing tool,
  another ffprobe failure or a failed write stays an `:internal` error. Regular TikTok
  videos still go through yt-dlp.
- Instagram posts are read logged out first: `Instagram.Url` (share links resolved with
  one request) → `Instagram.GraphQL` → `Instagram.Page` (no cookies) → `Ytdlp.metadata/3`
  (yt-dlp always gets the cookies). The browser and app ids these requests send live in
  `Angler.Media.Instagram` (`user_agent/0`, `app_id/0`, `asbd_id/0`).
  Photo-only posts (one photo or several) then get one logged-in lookup when a cookies
  file is configured (`Instagram.Soundtrack` → `Instagram.MediaInfo`,
  `GET /api/v1/media/<pk>/info/`, the only request in the app's own code carrying
  Instagram cookies; `Instagram.Music` reads `items[0].music_metadata`): unmuted music
  makes a slideshow, anything else an album. Login, checkpoint and rate-limit answers give
  an album, never a retry. Carousels with a video, and photo posts without music, become an album
  (`Angler.Media.Album`: CDN-only fetches (`Angler.Media.Instagram.Cdn`) with a shared byte
  budget, photos checked by `Album.Photo`, videos through `Media.Prepare`, files at
  `<entry dir>/album/NN/`); a single video (reel) goes to yt-dlp with the post text as title.
- Threads posts (yt-dlp has no Threads extractor) are read logged out only, never with
  cookies: `Threads.Url` (share links resolved with one request) → `Threads.Page` (the
  post page loaded like a browser navigation; the post is the `data.media` with its code
  in a `data-sjs` blob, found by code and shape, not by query name) →
  `Instagram.Post.from_media/1` (same shape; `Post.site` is `"Threads"`, which names the
  post in titles, messages and the extractor). A single video is fetched from the CDN by
  `Threads.Video` (`<dir>/source.mp4`, a `:video` download), photo-only posts with music
  (`Threads.Music`: logged out, a 30 s clip from `audio_start_time_in_ms`) go through
  `Slideshow.Instagram`, other posts with media are albums; posts without media are
  `:unsupported`. Requests go only to `www.threads.com` URLs built from parsed codes
  (one redirect to the same post is followed by hand), media only from `Instagram.Cdn`.
- Albums: `Entry.media_kind == :album`, items in `entries.media_items`
  (`Angler.Entries.MediaItem`, paths relative to the entry dir, validated by
  `Angler.Storage.Album` before any use). `Angler.Pipeline.AlbumUpload` sends them in parts
  of up to 10 (`AlbumUpload.Plan`), records file ids after each part and never re-sends a
  delivered part (a partly delivered album fails as partial). Albums are never re-used by
  file id. Post text over 1024 UTF-16 units follows as a message once the media was delivered
  (`Pipeline.Caption.split/3`); never on its own after an unconfirmed upload, so in local mode
  the media also gets it cut to 1024 (`Pipeline.Delivery.caption/1`).
- Cookies (`YTDLP_COOKIES_FILE`, `Angler.Media.Cookies`) are a fallback, with one exception:
  the music lookup of Instagram photo posts (one GET per attempt, only with an Instagram
  `sessionid`). yt-dlp always gets a private copy (`Angler.Media.Ytdlp.Runner`, shared by
  downloads and metadata runs); TikTok post pages load once more with them when hidden or
  unreadable. Requests carrying cookies never follow redirects and never log transport
  error messages.
- External tools are wrapped behind `Angler.Media` (a behaviour, swappable in tests)
  and HTTP calls to Telegram go through `Angler.Telegram` (Req; tests stub it with
  `Req.Test` under the name `Angler.Telegram`; likewise `Angler.Media.TikTok`,
  `Angler.Media.Instagram` (Instagram and the CDN Instagram and Threads share) and
  `Angler.Media.Threads`).
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
