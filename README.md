# Angler

A self-hosted Telegram bot that turns links into videos and photos. Post a TikTok,
Instagram, Threads, YouTube, X, Reddit or similar link in a chat, and Angler
replies to the message with the media itself: the video, downloaded with
[yt-dlp](https://github.com/yt-dlp/yt-dlp), shrunk with ffmpeg when needed so it
fits Telegram's upload limit, and playable inline, or the photos and videos of an
Instagram or Threads post as an album. A web dashboard shows every link as it moves through
the pipeline and lets you tune storage and filtering.

## Features

- **Works in groups, private chats and channels.** Up to 5 links per message.
  Replies land in the right forum topic.
- **Fits Telegram's limits automatically.** Angler prefers formats that already
  fit, remuxes when only the container is wrong, and otherwise re-encodes to
  H.264/AAC MP4 (two-pass, sized to the limit) with a thumbnail and correct
  dimensions.
- **Durable queue.** Links are stored in Postgres before anything else happens.
  Work interrupted by a crash or restart is picked up again on the next start,
  and temporary failures (network errors, rate limits, timeouts) are retried
  with backoff. See [Restarts](#restarts) for the fine print.
- **Photo slideshows.** TikTok photo posts (`/photo/` links, short links, or
  slideshows behind `/video/` links), Threads photo posts with music, and
  Instagram photo posts with music when [cookies](#cookies) are configured, are
  turned into a video: the photos in order, each shown for 3–6 s and cycled for
  the length of the sound (up to 90 s; a single photo stays up for the whole
  sound), on a canvas matching the photos' shape with a blurred fill. Instagram
  and Threads posts play the part of the song the post uses (on Threads, the
  30 seconds from where the post's clip starts), looped when the photos outlast
  it. TikTok posts without a sound become silent videos.
- **Instagram photos and carousels.** Photo posts and carousels (up to 20 photos
  and videos) are sent as they are, in order: a single photo as a photo, anything
  more as Telegram albums of up to 10 items (larger carousels arrive as several
  albums), with the post text. Videos in a carousel are fitted to the upload
  limit like any other video; photos Telegram doesn't accept (over 10 MB, or
  extreme sizes) are left out. Reels still go through yt-dlp, with the post text
  as their caption. Photo posts with music become a slideshow video instead when
  a cookies file is configured (Instagram shows the music only to logged-in
  visitors); carousels with videos stay albums. Posts are read without logging
  in; [cookies](#cookies) are otherwise only a fallback. Share links,
  `instagr.am` links and `?img_index=` links to the same post work too.
- **Threads posts.** yt-dlp can't read Threads, so Angler reads the post page
  itself, logged out and without cookies, and delivers posts like Instagram's: a
  video as a video (fitted to the upload limit like any other), photos and
  carousels as albums with the post text, and photo posts with music as
  slideshow videos (Threads shows the music to logged-out visitors). Posts
  without photos or videos (text, links, quotes, GIFs) are refused, and only the
  linked post is sent, not the rest of its thread. Share links
  (`threads.com/share/...`), `/t/` links and `threads.net` links work too. Posts
  Threads doesn't show to logged-out visitors fail.
- **Post text as captions.** Media is posted with its title or post text (the
  YouTube title, the TikTok, Instagram or Threads post text, ...) as a plain-text caption.
  Text longer than Telegram's 1024-character caption limit follows as a separate
  message replying to the media (up to 4096 characters) instead of being cut.
  With the local Bot API server, whose long uploads may never be confirmed, the
  media also gets the start of such a text as its caption: the full text follows
  only once Telegram confirmed the upload.
  Titles that are just the link or the video id are left out. Can be turned off
  in the settings.
- **Instant repeats.** A video link that was already delivered is re-sent by
  Telegram file id, with no second download. Albums are downloaded again every
  time.
- **Respects rate limits.** Per-chat, per-group and global send limits and
  Telegram's `retry_after` are handled for you.
- **Live dashboard.** Watch progress in real time; retry, cancel or delete
  entries; preview kept videos and albums; adjust storage and filtering without a
  restart.
- **Storage under control.** Kept media is evicted by age (retention) and by
  total size (storage cap).
- **Up-to-date yt-dlp.** Optionally tracks yt-dlp's nightly or stable channel,
  because sites change often.
- **Up to 2000 MB uploads** with the optional local Bot API server.
- **One `docker compose up`.** Multi-arch image (amd64/arm64), with optional
  Caddy (automatic HTTPS) and Cloudflare Tunnel services.

## How it works

```
Telegram ── webhook (or polling) ──▶ Angler
                                      │ extract links, apply host/chat allowlists
                                      ▼
                         Postgres "entries" table (the job queue)
                                      │
                                      ▼
        Broadway pipeline ── download (yt-dlp, post photos) ─▶ ffprobe/ffmpeg: fit to size
                                      │
                                      ▼
          sendVideo / sendPhoto / sendMediaGroup (rate-limited) as a reply
                                      │
                                      ▼
                    LiveView dashboard: live status, progress, settings
```

The pipeline runs `DOWNLOAD_CONCURRENCY` downloads/encodes and
`UPLOAD_CONCURRENCY` uploads at a time. Every state change is written to Postgres
and broadcast to the dashboard. While a link is processed, the bot reacts with 👀,
then clears the reaction on success or reacts with 🤷 on failure (if reactions
are enabled and allowed in the chat).

## Quick start

You need a Linux machine (or any Docker host) with Docker Engine 25+ and Docker
Compose v2.24+ (Docker Desktop works too).

### 1. Create the bot

1. Talk to [@BotFather](https://t.me/BotFather), send `/newbot` and keep the token.
2. **Let the bot see messages in groups.** By default, bots in groups only see
   commands and replies to them, not ordinary messages with links. Either:
   - send `/setprivacy` to @BotFather, choose the bot, then **Disable**, and
     afterwards **remove and re-add the bot** to every group it is already in
     (the setting only applies when the bot joins); or
   - make the bot an **admin** of the group.

   In channels, the bot must be an admin to see posts.

### 2. Configure

```sh
git clone <repository url> angler && cd angler
cp .env.example .env
```

Fill in the "Required" section of `.env`:

```sh
openssl rand -hex 24      # POSTGRES_PASSWORD (URL-safe)
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -base64 24   # DASHBOARD_PASSWORD
```

Also set `TELEGRAM_BOT_TOKEN`. `PUBLIC_URL` depends on the next step.

- docker compose expands `$NAME` inside `.env` values: a value containing `$`
  must be put in single quotes (`DASHBOARD_PASSWORD='pa$word'`), otherwise it
  is silently cut off.
- `POSTGRES_PASSWORD` is only applied when the database is created by the first
  `docker compose up`. See [Changing the database password](#changing-the-database-password)
  before changing it later.

### 3. Choose how Telegram reaches Angler

Telegram either pushes updates to a public HTTPS URL (webhook) or Angler asks
for them (polling). Pick one:

| Option | You need | Uploads | In `.env` |
|---|---|---|---|
| **A. Caddy** | A domain pointing at this machine, ports 80/443 open | 50 MB | `COMPOSE_PROFILES=caddy`, `PUBLIC_URL`, `ANGLER_DOMAIN`, `ACME_EMAIL` |
| **B. Cloudflare Tunnel** | A domain on Cloudflare; no open ports | 50 MB | `COMPOSE_PROFILES=tunnel`, `PUBLIC_URL`, `CLOUDFLARE_TUNNEL_TOKEN` |
| **C. Local Bot API server** | `api_id`/`api_hash` from my.telegram.org; no public address | **2000 MB** | `COMPOSE_PROFILES=local-bot-api` and the local Bot API settings |
| **D. Polling** | Nothing | 50 MB | `TELEGRAM_MODE=polling` |

Polling is the simplest and fine for personal use. With a webhook, Telegram
pushes updates to Angler instead of Angler holding a long-poll request open. The
local Bot API server also lifts the upload limit, which matters for longer videos.

<details>
<summary><b>A. Caddy (automatic HTTPS)</b></summary>

1. Create a DNS `A`/`AAAA` record for your domain (e.g. `angler.example.com`)
   pointing at this machine, and open ports 80 and 443.
2. In `.env`:
   ```sh
   COMPOSE_PROFILES=caddy
   PUBLIC_URL=https://angler.example.com
   ANGLER_DOMAIN=angler.example.com
   ACME_EMAIL=you@example.com
   ```
   Both `ANGLER_DOMAIN` and `ACME_EMAIL` are required with this profile; Caddy
   refuses to start without them.

Caddy (`deploy/caddy/Caddyfile`) obtains a Let's Encrypt certificate and proxies
everything to the app, including the dashboard and its websocket. Telegram only
delivers webhooks over HTTPS with a valid certificate on port 443, 80, 88 or 8443.
This puts the dashboard on the internet; see
[Keeping the dashboard private](#keeping-the-dashboard-private).
</details>

<details>
<summary><b>B. Cloudflare Tunnel (no open ports)</b></summary>

1. In the Cloudflare dashboard, go to **Zero Trust → Networks → Tunnels**, create
   a `cloudflared` tunnel and copy its token.
2. Add a **public hostname** (e.g. `angler.example.com`) with service
   **HTTP** → `app:4000`. Use `app`, not `localhost`: cloudflared runs in its own
   container, where `localhost` is cloudflared itself, so `localhost:4000` shows
   Cloudflare's *Bad gateway (Host: Error)* page.
3. In `.env`:
   ```sh
   COMPOSE_PROFILES=tunnel
   PUBLIC_URL=https://angler.example.com
   CLOUDFLARE_TUNNEL_TOKEN=eyJ...
   ```

This puts the dashboard on the internet, protected only by `DASHBOARD_PASSWORD`.
Consider putting Cloudflare Access in front of the hostname (see
[Keeping the dashboard private](#keeping-the-dashboard-private)). Then add a
bypass rule for `/telegram/webhook`: Telegram must reach it without logging in.
Its requests are authenticated with a secret token instead.
</details>

<details>
<summary><b>C. Local Bot API server (2000 MB uploads)</b></summary>

Runs Telegram's own [Bot API server](https://github.com/tdlib/telegram-bot-api)
next to Angler. The app sends videos to it by file path, with no upload and up to
2000 MB, and the webhook stays on the internal compose network, so nothing needs
to be exposed.

1. Get an `api_id` and `api_hash` at <https://my.telegram.org> → *API development tools*.
2. In `.env` (leave `PUBLIC_URL` empty):
   ```sh
   COMPOSE_PROFILES=local-bot-api
   TELEGRAM_API_ID=1234567
   TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
   TELEGRAM_API_BASE_URL=http://telegram-bot-api:8081
   TELEGRAM_LOCAL_MODE=true
   TELEGRAM_WEBHOOK_URL=http://app:4000/telegram/webhook
   ```
   These belong together: Angler refuses to start with `TELEGRAM_LOCAL_MODE=true`
   or an `http://` webhook URL while `TELEGRAM_API_BASE_URL` still points at the
   cloud API.
3. After `docker compose up -d` (step 4), log the bot out of Telegram's cloud
   API **once**. Otherwise the cloud server may keep receiving its updates. Then
   restart the app:
   ```sh
   docker compose exec app bin/angler rpc "Angler.Telegram.log_out_from_cloud() |> IO.inspect()"
   docker compose restart app
   ```

To go back to the cloud API, remove these settings. Telegram only lets a bot log
in to the cloud again 10 minutes after the logout.
</details>

<details>
<summary><b>D. Polling</b></summary>

Set `TELEGRAM_MODE=polling` and leave `PUBLIC_URL` empty (or keep it for
the dashboard address, together with `TELEGRAM_MODE=polling`). Angler removes any
webhook and long-polls Telegram. Only one process may poll a bot at a time.
</details>

### 4. Start

```sh
docker compose up -d
docker compose logs -f app     # Ctrl-C to stop following
```

The first start builds the image, which takes a few minutes. Migrations run
automatically on every start. The optional services come from
`COMPOSE_PROFILES` in `.env`. `docker compose --profile caddy up -d` does the
same for a single command, but then every later command (`logs`, `down`, …) needs
the flag too.

### 5. Open the dashboard

Open <http://localhost:4000> on the Docker host and log in as `admin` (or
`DASHBOARD_USERNAME`) with `DASHBOARD_PASSWORD`. The **Settings** page shows
whether the bot and webhook are working.

- By default, the dashboard is only published on `127.0.0.1`. From another
  machine, use an SSH tunnel (`ssh -L 4000:127.0.0.1:4000 you@server`), set
  `ANGLER_BIND=0.0.0.0` for LAN access, or use your `PUBLIC_URL` with options A
  and B.
- Send the bot a link in a private chat to try it. `/help` explains what it does.

## Telegram limits

- **Upload size: 50 MB** through the cloud Bot API. Angler asks yt-dlp for a
  format that already fits. Otherwise it re-encodes with ffmpeg to just under
  the limit, lowering resolution and frame rate as needed. As a rule of thumb,
  50 MB holds a few minutes of 720p or about half an hour at the lowest quality
  Angler uses. Anything longer fails with *"too long to fit"*. You can lower the
  target on the Settings page.
- **Upload size: 2000 MB** with the local Bot API server (option C). Far fewer
  videos need re-encoding. The local server answers only after it has pushed the
  whole file to Telegram and closes connections that stay idle for about 500 s, so
  an upload that takes longer than that (a very large file on a slow uplink) can't
  be confirmed. Angler then marks the entry *"Telegram did not confirm the upload
  in time; it may still appear in the chat"* instead of sending it again.
- **Albums:** up to 10 photos and videos per album message, each counted as one
  message for the rate limits. Through the cloud Bot API one album may carry at
  most 50 MB in total, so large carousels are split into more albums. Photos may
  be at most 10 MB, with width + height up to 10,000 pixels and a ratio of at
  most 20:1. When a later album of a carousel can't be sent, the entry fails as
  sent in part (*"Only N of M items could be sent."*); what was delivered is never
  sent again.
- **Rate limits:** about 1 message per second per chat, 20 per minute per group
  and about 30 per second overall. Angler schedules sends within these limits and
  obeys Telegram's `retry_after` automatically, so a burst of links queues up
  instead of failing.
- **Privacy mode:** see [step 1](#1-create-the-bot). Without it, the bot cannot
  see links in groups.

## Dashboard

- **Entries** (`/`): every link with its status (queued, downloading, processing,
  uploading, done, failed, cancelled), live progress, chat, size and duration.
  Filter by status, search, and retry, cancel or delete entries. Each entry has a
  detail page with the full error, media information and a preview while the files
  are kept: the video, or an album's photos and videos with its post text.
- **Settings** (`/settings`), applied immediately without a restart:

  | Setting | Default | |
  |---|---|---|
  | Storage cap | 10,240 MB | Total size of kept media; the oldest is deleted first |
  | Retention | 7 days | How long delivered media is kept; 0 deletes it right after sending |
  | Max source size | 1024 MB | Larger downloads are refused |
  | Max duration | 30 min | Longer videos are refused before downloading |
  | Upload target | Bot API maximum | Size produced videos must fit (50 or 2000 MB) |
  | Allowed hosts | TikTok (and `tt.site`), Instagram (and `instagr.am`), Threads, YouTube, X, Reddit, … | Only links to these sites; empty allows any public site (private and LAN addresses stay blocked, see `ALLOW_PRIVATE_NETWORK_DOWNLOADS`). `instagr.am` and `tt.site` are only in the defaults of new installs: add them to an existing list for Instagram's short links and TikTok's `www.tt.site` share links |
  | Allowed chats | any | Only messages from these chat ids. **Fill this in** unless anyone may use your bot, see [Who can use the bot](#who-can-use-the-bot) |
  | Failure replies | private chats | Explain failures: never, in private chats, or everywhere |
  | Reactions | on | 👀 while working, 🤷 on failure |
  | Post text as captions | on | Post the title or post text as the caption (plain text); text longer than 1024 characters follows as a separate message |
  | History | 90 days | Finished entries older than this are removed from the list; 0 keeps them forever |

  The page also shows the Telegram connection (bot, webhook status and last
  error, with a *Re-register webhook* button), storage usage (with *Run cleanup
  now*) and tool versions.
- **System** (`/system`): Phoenix LiveDashboard with BEAM, database and request
  metrics.

All pages are protected with HTTP basic auth. `/health` (no auth) returns 200
when the database is reachable.

## Configuration reference

All settings are environment variables, set in `.env`. Booleans accept `true`/`false`,
`1`/`0`, `yes`/`no` or `on`/`off` in any case; anything else stops the app at
start with an error naming the variable. URLs must include `https://` (or
`http://`). Put values that contain `$` in single quotes. Storage and filtering
are configured on the dashboard, not here.

**Read by Angler**

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | *required* | Bot token from @BotFather |
| `SECRET_KEY_BASE` | *required* | Signs the session cookie (`openssl rand -base64 48`) |
| `DASHBOARD_PASSWORD` | *required* | Dashboard password; use a generated one (`openssl rand -base64 24`) |
| `DASHBOARD_USERNAME` | `admin` | Dashboard user name |
| `PUBLIC_URL` | `http://localhost:4000` | Public address of this instance, a full URL such as `https://angler.example.com`. Its host is allowed to open the dashboard; when set, webhook mode is used by default |
| `TELEGRAM_MODE` | `webhook` if a webhook URL is known, else `polling` | `webhook`, `polling` or `disabled` |
| `TELEGRAM_WEBHOOK_URL` | `PUBLIC_URL` + `/telegram/webhook` | Where Telegram posts updates |
| `TELEGRAM_WEBHOOK_SECRET` | derived from the token | Secret Telegram sends with each webhook request (1-256 of `A-Z a-z 0-9 _ -`) |
| `TELEGRAM_WEBHOOK_MAX_CONNECTIONS` | `40` | Parallel webhook connections Telegram may open (1-100) |
| `TELEGRAM_API_BASE_URL` | `https://api.telegram.org` | Bot API server, e.g. `http://telegram-bot-api:8081` |
| `TELEGRAM_LOCAL_MODE` | `false` | The Bot API server runs with `--local` (2000 MB uploads by file path); needs `TELEGRAM_API_BASE_URL` set to that server |
| `DOWNLOAD_CONCURRENCY` | `2` | Links downloaded and converted in parallel |
| `UPLOAD_CONCURRENCY` | `2` | Videos or albums uploaded in parallel |
| `MAX_ATTEMPTS` | `3` | Attempts per link for temporary failures |
| `PIPELINE_ENABLED` | `true` | `false` pauses processing (links are still queued) |
| `YTDLP_UPDATE_CHANNEL` | *empty* (`.env.example`: `nightly`) | `nightly` or `stable`: keep a self-updating yt-dlp in `/data/bin`; empty uses the bundled one |
| `YTDLP_COOKIES_FILE` | *empty* | Path of a Netscape `cookies.txt` inside the container, for yt-dlp, as a logged-in fallback for Instagram and TikTok posts, and to find the music of Instagram photo posts, see [Cookies](#cookies) |
| `ALLOWED_ORIGINS` | *empty* | Extra host names the dashboard may be opened from (comma separated). `localhost`, private IPs and LAN names (`nas`, `*.local`, `*.lan`, …) always work |
| `ALLOW_PRIVATE_NETWORK_DOWNLOADS` | `false` | `true` lets links (and the redirects yt-dlp follows) reach this machine, your LAN and other private addresses, including the compose services. While it is `false`, yt-dlp goes through Angler's own egress guard, which connects directly and ignores `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`; if the server can only reach the internet through such a proxy, set this to `true` |
| `POOL_SIZE` | `10` | Database connections |
| `ECTO_IPV6` | `false` | Connect to the database over IPv6 |
| `YTDLP_PATH`, `FFMPEG_PATH`, `FFPROBE_PATH` | `yt-dlp`, `ffmpeg`, `ffprobe` | Tool executables (all included in the image) |
| `DATABASE_URL` | set by `compose.yaml` | `ecto://angler:POSTGRES_PASSWORD@db/angler` |
| `DATA_DIR` | `/data` (set by `compose.yaml`) | Media, caches and the managed yt-dlp |
| `PORT` | `4000` (fixed in `compose.yaml`) | HTTP port inside the container |

**Read by docker compose**

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_PASSWORD` | *required* | Database password; keep it URL-safe (`openssl rand -hex 24`). Only applied when the database is first created, see [Changing the database password](#changing-the-database-password) |
| `COMPOSE_PROFILES` | *empty* | Optional services to run: `caddy`, `tunnel`, `local-bot-api` |
| `ANGLER_BIND` | `127.0.0.1` | Host address the dashboard port is published on (`0.0.0.0` for LAN) |
| `ANGLER_PORT` | `4000` | Host port for the dashboard |
| `ANGLER_IMAGE` | `angler:local` | Tag of the image compose builds and runs |
| `ANGLER_DOMAIN`, `ACME_EMAIL` | *empty* | Caddy: your domain and certificate contact address |
| `CLOUDFLARE_TUNNEL_TOKEN` | *empty* | Cloudflare Tunnel token |
| `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` | *empty* | Local Bot API server credentials from my.telegram.org |

## Operations

### Updating

```sh
git pull
docker compose build --pull
docker compose up -d
```

Database migrations run automatically on start. Tool versions (Elixir/OTP,
ffmpeg, deno, yt-dlp) are pinned as `ARG`s at the top of the `Dockerfile`.
Between rebuilds, `YTDLP_UPDATE_CHANNEL` keeps yt-dlp current: a managed copy in
the data volume is updated shortly after start and then daily. That is usually
all it takes when a site suddenly stops working.

### Restarts

On `docker compose stop`, `restart` or an `up -d` that recreates the app, the
pipeline gives running downloads, conversions and uploads 15 seconds to finish.
Whatever is still running then is stopped and picked up again on the next
start. An upload cut off this way may already have reached Telegram
(most likely with long uploads through the local Bot API server), so that video
can occasionally be posted twice. An album interrupted after part of it was
delivered is not sent again: it fails as sent in part. An upload that Telegram
doesn't confirm while the app keeps running is not retried: the entry fails with
*"Telegram did not confirm the upload in time; it may still appear in the chat"*.

Stopping takes at most about 15 s × (1 + `DOWNLOAD_CONCURRENCY` +
`UPLOAD_CONCURRENCY`), 75 s with the defaults. `stop_grace_period` in
`compose.yaml` is 120 s; raise it if you raise the concurrency a lot, or Docker
kills the app before it has stopped cleanly.

### Who can use the bot

By default Angler answers **anyone** who messages the bot or adds it to a group,
and bot usernames are easy to find. Every link costs CPU time, disk space and
bandwidth, and with [cookies](#cookies) it is downloaded with your logged-in
account, so a stranger could fetch what only your account can see. Unless you
want a public bot, fill in **Allowed chats** on the Settings page: send the bot a
link from each chat you want to use, open that entry on the dashboard, and copy
its chat id (group ids are negative).

Channel posts that Telegram automatically copies into a channel's linked
discussion group are skipped when the channel itself is allowed (the channel
post already gets the video). If the bot is only a member of the discussion
group, list only the group's id in **Allowed chats** to get videos there.

### Keeping the dashboard private

With options A and B, the dashboard (including settings and `/system`, Phoenix
LiveDashboard) is reachable from the internet, protected only by HTTP basic auth
with `DASHBOARD_PASSWORD`, and nothing slows down password guessing. Use a
generated password, and consider publishing only the webhook:

- **Caddy:** uncomment the two `@dashboard` lines in `deploy/caddy/Caddyfile`
  and run `docker compose restart caddy`. Everything except `/telegram/webhook`
  then answers 404; open the dashboard over an SSH tunnel
  (`ssh -L 4000:127.0.0.1:4000 you@server`, then <http://localhost:4000>) or on
  the LAN (`ANGLER_BIND=0.0.0.0`).
- **Cloudflare Tunnel:** put a Cloudflare Access application (Zero Trust →
  Access) in front of the hostname, with a bypass policy for `/telegram/webhook`.

### Changing the database password

The Postgres image only reads `POSTGRES_PASSWORD` when it creates the database
(the first `docker compose up`). Changing it in `.env` afterwards makes the app
fail with *"password authentication failed for user angler"*. Change it in the
database as well:

```sh
docker compose exec db psql -U angler -c "ALTER USER angler PASSWORD 'new-password'"
# then set POSTGRES_PASSWORD=new-password in .env and:
docker compose up -d
```

On a fresh install without data you want to keep, `docker compose down -v`
deletes the database (and all other volumes) instead, and the next `up` creates
it with the current password.

### Cookies

Some content needs a logged-in session: private, age-restricted or members-only
videos, and Instagram or TikTok posts hidden from logged-out visitors (Instagram
also rate-limits anonymous access at times).

How Angler uses the cookies file:

- **yt-dlp** gets a fresh copy for every run: every video download (including
  Instagram reels) uses the cookies.
- **Instagram posts** are read logged out first. Only when Instagram hides the
  post from logged-out visitors, rate-limits them, or can't be read, Angler asks
  yt-dlp (with the cookies) for the post instead. Without cookies, hidden posts
  fail right away (*"This Instagram post is private, deleted or age-restricted"*)
  and rate-limited ones are tried again later.
- **Instagram photo posts** (a photo, or photos only) are looked up once more
  with the cookies, one request to Instagram's media info API, to find their
  music, which Instagram shows only to logged-in visitors. With music the post
  becomes a slideshow video, otherwise an album. When the file has no Instagram
  login (or it has expired), when Instagram doesn't accept it (logged out, a
  checkpoint) or when it rate-limits the account, the post goes out as an album
  and the log says why. Export the cookies again for a missing, expired or
  rejected login; a rate limit wears off by itself.
- **TikTok posts** are looked up logged out first (to tell photo posts from
  videos). When TikTok hides the post, or its page can't be read, the page is
  loaded once more with the cookies. Short links are always resolved without them.
- **Threads posts** never use the cookies: Angler reads them logged out only.
- Angler never sends the cookies to the servers the photos, videos and songs
  come from, to short-link resolvers or to any redirect target. For its own
  requests it skips lines it can't use (logged by line number, never their
  contents) and ignores files over 1 MB.

The risks:

- Everything fetched with the cookies is fetched as your account, whoever sent
  the link: private posts that account can see can be reposted by anyone in an
  allowed chat. **Fill in Allowed chats first** (see
  [Who can use the bot](#who-can-use-the-bot)); otherwise anyone who finds the bot
  can use your logged-in session.
- Automated access can get an account restricted or banned. **Use a throwaway
  account**, never your personal one.

1. Export a **Netscape-format `cookies.txt`** from a browser where that account is
   logged in, e.g. with a "cookies.txt" browser extension or
   `yt-dlp --cookies-from-browser firefox --cookies cookies.txt` on your desktop.
2. Put it next to `compose.yaml` and make it readable by the container user
   (uid 65534): `sudo chown 65534 cookies.txt && sudo chmod 600 cookies.txt`.
3. Mount it read-only with a `compose.override.yaml` (merged automatically):
   ```yaml
   services:
     app:
       volumes:
         - ./cookies.txt:/config/cookies.txt:ro
   ```
4. Set `YTDLP_COOKIES_FILE=/config/cookies.txt` in `.env` and run
   `docker compose up -d`.

Angler reads the file every time it needs it and gives yt-dlp a fresh copy for
every run, so the read-only mount is fine and a replaced file takes effect without
a restart. Cookies expire. If a site starts failing with "login required" again,
export them again.

### Backups

Everything worth keeping (entries history, settings, cached Telegram file ids)
is in Postgres:

```sh
docker compose exec -T db pg_dump -U angler angler > angler-$(date +%F).sql
```

To restore into a fresh database:

```sh
docker compose stop app
docker compose exec -T db dropdb -U angler angler
docker compose exec -T db createdb -U angler angler
docker compose exec -T db psql -q -U angler -d angler < angler-2026-09-26.sql
docker compose start app
```

The `media` volume only holds recently delivered media (subject to retention)
and caches, so it doesn't need a backup.

### Data and volumes

| Volume | Contents |
|---|---|
| `pgdata` | Postgres 18 (data in `/var/lib/postgresql/18/docker`) |
| `media` | `/data/media/<entry id>/` videos, album photos and thumbnails, `/data/cache` (yt-dlp, deno), `/data/bin` (managed yt-dlp) |
| `telegram-bot-api-data` | Local Bot API server state (option C) |
| `caddy_data`, `caddy_config` | Certificates and Caddy state (option A) |

The app runs as `nobody` (uid 65534). The local Bot API server reads videos from
the same `media` volume, read-only, at the same path.

## Troubleshooting

- **The bot ignores links in a group.** Privacy mode is still on: disable it with
  `/setprivacy` in @BotFather, then remove and re-add the bot, or make the bot an
  admin. Also check *Allowed hosts* and *Allowed chats* on the Settings page.
- **Nothing arrives at all.** The Settings page shows the webhook status and
  Telegram's last delivery error (from `getWebhookInfo`). Typical causes: a
  `PUBLIC_URL` that isn't reachable over HTTPS, a certificate Caddy couldn't
  obtain (check `docker compose logs caddy`: DNS and ports 80/443), or a wrong
  tunnel hostname. You can also ask Telegram directly:
  `curl https://api.telegram.org/bot<token>/getWebhookInfo`.
- **"409 Conflict: terminated by other getUpdates request".** Two processes poll
  the same bot (e.g. a development instance with the production token), or a
  webhook was set by another instance. Run one instance per bot token.
- **"Video is too long to fit into 50 MB".** At that size and duration the
  result would be unwatchable. Use the local Bot API server (2000 MB), or lower
  *Max duration* so such links fail fast.
- **Instagram/TikTok/YouTube downloads suddenly fail.** Sites change often. Set
  `YTDLP_UPDATE_CHANNEL=nightly` (or rebuild the image), and add
  [cookies](#cookies) for sites that require a login. Instagram posts that Angler
  can't read itself are handed to yt-dlp, so a current yt-dlp helps there too.
- **Threads links fail with "not shown to logged-out visitors".** Threads keeps
  some posts (private accounts, deleted posts, and some others) from visitors who
  aren't logged in, and Angler reads Threads logged out only. Links to a post
  without photos or videos (text only) fail as having none.
- **Instagram photo posts with music arrive as albums.** Angler needs a cookies
  file with a logged-in Instagram session to see a post's music. The log tells
  why (no Instagram login in the file or it has expired, login not accepted,
  rate limited, muted music).
- **The dashboard loads but stays disconnected.** The websocket origin was
  rejected: add the host name you use to `ALLOWED_ORIGINS` (or set it as
  `PUBLIC_URL`).
- **The app exits right after starting.** `docker compose logs app` names the
  setting at fault, e.g. a `PUBLIC_URL` without `https://`, a boolean that isn't
  `true`/`false`, or local Bot API settings that don't fit together.
- **"password authentication failed for user angler".** `POSTGRES_PASSWORD` was
  changed after the database was created, see
  [Changing the database password](#changing-the-database-password).
- **Entries are retried with "Not enough free disk space".** Angler doesn't
  start a download while the disk holding the `media` volume has less than 2 GB
  or 5 % free (whichever is more), and tries again a few minutes later. Free up
  space, or lower *Storage cap* / *Retention*.
- **A password or other secret doesn't work.** A `$` in `.env` starts a
  variable: put the value in single quotes.
- **Logs and health:** `docker compose logs -f app`, `docker compose ps`, and
  `curl http://localhost:4000/health`. For a remote console into the running app,
  use `docker compose exec app bin/angler remote`.

## Development

Requirements: Elixir 1.20 / Erlang/OTP 29, Docker (for Postgres), and on your
`PATH`: `ffmpeg`, `ffprobe`, `yt-dlp` and `deno`.

```sh
docker run -d --name angler-dev-db -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18
mix setup                                   # deps, database, assets
TELEGRAM_BOT_TOKEN=<test bot token> TELEGRAM_MODE=polling iex -S mix phx.server
```

Then open <http://localhost:4000> (user `admin`, password `admin` in development).
Use a **separate test bot** from @BotFather: polling removes the webhook of the
bot you use. Without `TELEGRAM_BOT_TOKEN`, the dashboard runs but no updates are
received.

```sh
mix test                    # needs the Postgres above; ffmpeg-based tests run when ffmpeg/ffprobe are on PATH
mix test --include network  # also tests that reach the internet (real yt-dlp downloads, live Instagram and Threads posts)
mix precommit               # compile with warnings as errors, format, test: run before committing
```

To build the production image yourself: `docker build -t angler .`, or for
both architectures, `docker buildx build --platform linux/amd64,linux/arm64 -t angler .`.

## License

MIT, see [LICENSE](LICENSE).
