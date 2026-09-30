defmodule Angler.Entries.Entry do
  @moduledoc """
  A single link found in a Telegram message, and everything that happened while
  turning it into a reply with its video, or its photos and videos (an album, see
  `Angler.Entries.MediaItem`).

  The table doubles as the durable job queue consumed by `Angler.Pipeline`.

  Status lifecycle:

      queued ──claim──▶ downloading ─▶ processing ─▶ uploading ─▶ done
         ▲                   │              │            │
         └──── retry ────────┴──────────────┴────────────┴──▶ failed
      queued ─▶ cancelled (from the dashboard)

  `failed` and `cancelled` entries can be re-queued from the dashboard.
  """
  use Ecto.Schema

  alias Angler.Entries.MediaItem

  @statuses [:queued, :downloading, :processing, :uploading, :done, :failed, :cancelled]
  @active_statuses [:downloading, :processing, :uploading]
  @terminal_statuses [:done, :failed, :cancelled]

  @error_kinds [
    # Worth retrying: network hiccups, Telegram 429/5xx, site rate limits
    :transient,
    # yt-dlp can't handle this URL / no video in the post
    :unsupported,
    # Can't fit into Telegram's upload limit, or exceeds the configured source limits
    :too_large,
    # Private/removed/geo-blocked/login-required content
    :unavailable,
    # Telegram rejected the request permanently (bot blocked, chat not found, ...)
    :telegram,
    # A step took longer than allowed
    :timeout,
    # Bugs, unexpected tool output, disk errors
    :internal
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "entries" do
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :stage_detail, :string

    field :url, :string
    field :source_host, :string

    field :update_id, :integer
    field :chat_id, :integer
    field :chat_type, :string
    field :chat_title, :string
    field :message_id, :integer
    field :message_thread_id, :integer
    field :from_id, :integer
    field :from_name, :string

    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :available_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string
    field :error_kind, Ecto.Enum, values: @error_kinds

    field :title, :string
    field :extractor, :string
    field :duration, :float
    field :width, :integer
    field :height, :integer
    field :video_codec, :string
    field :source_bytes, :integer
    field :output_bytes, :integer
    field :transcoded, :boolean, default: false
    # :slideshow for TikTok photo posts and Instagram photo posts with music,
    # assembled into a video (Angler.Media.Slideshow); :album for posts sent as their
    # photos and videos (media_items)
    field :media_kind, Ecto.Enum, values: [:video, :slideshow, :album]
    # An album's items in display order, see Angler.Entries.MediaItem; [] otherwise
    embeds_many :media_items, MediaItem, on_replace: :delete

    field :storage_path, :string
    field :stored_bytes, :integer, default: 0
    field :purged_at, :utc_datetime_usec

    field :telegram_file_id, :string
    field :telegram_file_unique_id, :string
    field :reply_message_id, :integer
    field :reused_file_id, :boolean, default: false

    timestamps()
  end

  @type status ::
          :queued | :downloading | :processing | :uploading | :done | :failed | :cancelled
  @type error_kind ::
          :transient | :unsupported | :too_large | :unavailable | :telegram | :timeout | :internal
  @type t :: %__MODULE__{}

  @doc "All statuses, in lifecycle order."
  def statuses, do: @statuses

  @doc "Statuses of entries currently held by a pipeline worker."
  def active_statuses, do: @active_statuses

  @doc "Statuses that will not change without an explicit retry."
  def terminal_statuses, do: @terminal_statuses

  def error_kinds, do: @error_kinds

  def active?(%__MODULE__{status: status}), do: status in @active_statuses
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc "Whether the dashboard may re-queue this entry."
  def retryable?(%__MODULE__{status: status}), do: status in [:failed, :cancelled, :done]

  @doc "Whether the dashboard may cancel this entry."
  def cancellable?(%__MODULE__{status: status}), do: status == :queued

  @doc "Private chats get the most verbose feedback from the bot."
  def private_chat?(%__MODULE__{chat_type: type}), do: type == "private"
end
