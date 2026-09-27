# syntax=docker/dockerfile:1

# Angler production image: the Elixir release plus the tools it drives
# (yt-dlp with deno as its JavaScript runtime, ffmpeg and ffprobe).
# Multi-arch (linux/amd64, linux/arm64):
#
#     docker build -t angler .
#     docker buildx build --platform linux/amd64,linux/arm64 -t angler .
#
# Every version is pinned; bump the ARGs below and rebuild to update.
# yt-dlp can additionally keep itself current at runtime (YTDLP_UPDATE_CHANNEL).

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim
ARG FFMPEG_VERSION=9.0.2
ARG DENO_VERSION=2.9.7

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# Static ffmpeg/ffprobe builds (libx264 + aac included) and the deno binary.
FROM docker.io/mwader/static-ffmpeg:${FFMPEG_VERSION} AS ffmpeg
FROM docker.io/denoland/deno:bin-${DENO_VERSION} AS deno

# ---------------------------------------------------------------------------
# yt-dlp standalone binary for the target architecture, verified by checksum
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS tools

ARG TARGETARCH
ARG YTDLP_VERSION=2026.08.19

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/yt-dlp

RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) asset=yt-dlp_linux ;; \
    arm64) asset=yt-dlp_linux_aarch64 ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  base="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}"; \
  curl -fsSLO "${base}/SHA2-256SUMS"; \
  curl -fsSLO "${base}/${asset}"; \
  grep " ${asset}\$" SHA2-256SUMS | sha256sum -c -; \
  install -m 0755 "${asset}" /usr/local/bin/yt-dlp

# ---------------------------------------------------------------------------
# Elixir release (same steps as `mix phx.gen.release --docker`)
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# download the tailwind and esbuild binaries for this platform
RUN mix assets.setup

COPY priv priv
COPY lib lib

# Compile the release before building assets: colocated hooks and CSS are
# extracted during compilation and imported by app.js / app.css.
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runner

# tini runs as PID 1: it forwards SIGTERM to the BEAM (graceful shutdown lets
# the pipeline drain) and reaps orphaned processes (e.g. children of yt-dlp or
# ffmpeg) that would otherwise linger as zombies.
# libsctp1 silences OTP's "Failed open sctp dynamic library" warning on every
# VM start (bin/angler rpc/eval included). curl is only used by the healthcheck.
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates tini libsctp1 curl \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

COPY --from=ffmpeg /ffmpeg /ffprobe /usr/local/bin/
COPY --from=deno /deno /usr/local/bin/deno
# The onefile yt-dlp binary unpacks itself into $TMPDIR (/tmp) on every run, so
# /tmp must stay writable and exec-able (don't mount a noexec tmpfs there).
COPY --from=tools /usr/local/bin/yt-dlp /usr/local/bin/yt-dlp

WORKDIR "/app"

# /data holds media, caches (yt-dlp, deno) and the self-updating yt-dlp copy.
# Docker copies this ownership into a new named volume mounted at /data.
# Everything stays world-readable (umask 022): the optional local Bot API
# server container (uid 101) reads the videos from the same volume.
RUN chown nobody /app \
  && mkdir -p /data/media /data/cache /data/bin \
  && chown -R nobody:nogroup /data \
  && chmod 0755 /data /data/media /data/cache /data/bin

# nobody has no home directory; yt-dlp and deno need a writable one for caches
ENV MIX_ENV="prod" \
  PHX_SERVER="true" \
  DATA_DIR="/data" \
  HOME="/data" \
  XDG_CACHE_HOME="/data/cache"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/angler ./

USER nobody

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3 \
  CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT:-4000}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
