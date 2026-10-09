defmodule Angler.Settings.Setting do
  @moduledoc """
  Runtime settings adjustable from the dashboard. Stored as a single row (id = 1).

  Sizes are in decimal megabytes (1 MB = 1,000,000 bytes), matching how Telegram
  documents its limits.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @failure_replies [:none, :private, :all]
  @max_chat_id Bitwise.bsl(1, 52)

  @default_hosts ~w(
    tiktok.com tt.site instagram.com instagr.am youtube.com youtu.be x.com twitter.com
    reddit.com redd.it facebook.com fb.watch vimeo.com twitch.tv threads.net threads.com
    bsky.app pinterest.com pin.it streamable.com dailymotion.com snapchat.com
  )

  @type t :: %__MODULE__{}

  @doc "Hosts processed out of the box; the dashboard can clear this to allow any host."
  def default_hosts, do: @default_hosts

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "settings" do
    # Total disk space the kept media may use; oldest files are evicted first.
    field :storage_limit_mb, :integer, default: 10_240
    # How long delivered media is kept on disk. 0 = delete right after sending.
    field :retention_hours, :integer, default: 168
    # Finished entries (and their files) are deleted this many days after they
    # finished. 0 = keep them forever.
    field :history_days, :integer, default: 90
    # yt-dlp refuses to download sources bigger than this.
    field :max_source_mb, :integer, default: 1024
    # Videos longer than this are rejected before downloading.
    field :max_duration_minutes, :integer, default: 30
    # Target size for uploads; nil = the Bot API maximum (50 MB cloud / 2000 MB local server).
    field :upload_limit_mb, :integer
    # Only links to these hosts (and their subdomains) are processed. Empty = any host.
    field :allowed_hosts, {:array, :string}, default: @default_hosts
    # Only messages from these chats are processed. Empty = any chat.
    field :allowed_chat_ids, {:array, :integer}, default: []
    # Where the bot replies with an error message when a link fails.
    field :failure_replies, Ecto.Enum, values: @failure_replies, default: :private
    # React to messages (👀 while working, 🤷 on failure) where reactions are allowed.
    field :reactions_enabled, :boolean, default: true
    # Post the title or post text as the caption (plain text); text too long for a
    # caption follows as a message of its own (see Angler.Pipeline.Caption.split/3).
    field :title_captions, :boolean, default: true

    timestamps()
  end

  @fields [
    :storage_limit_mb,
    :retention_hours,
    :history_days,
    :max_source_mb,
    :max_duration_minutes,
    :upload_limit_mb,
    :allowed_hosts,
    :allowed_chat_ids,
    :failure_replies,
    :reactions_enabled,
    :title_captions
  ]

  @doc """
  Validates dashboard input. `max_upload_mb` is the maximum the configured Bot API
  server accepts.
  """
  def changeset(setting, attrs, max_upload_mb) do
    setting
    |> cast(normalize_lists(attrs), @fields)
    |> validate_required([
      :storage_limit_mb,
      :retention_hours,
      :history_days,
      :max_source_mb,
      :max_duration_minutes,
      :failure_replies,
      :reactions_enabled,
      :title_captions
    ])
    |> validate_number(:storage_limit_mb,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 100_000_000
    )
    |> validate_number(:retention_hours,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 24 * 365
    )
    |> validate_number(:history_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 3650)
    |> validate_number(:max_source_mb,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100_000
    )
    |> validate_number(:max_duration_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 24 * 60
    )
    |> validate_number(:upload_limit_mb,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: max_upload_mb,
      message: "must be between 5 and #{max_upload_mb} (the Bot API server limit)"
    )
    |> validate_hosts()
    |> validate_chat_ids()
    |> put_default_lists()
  end

  # The dashboard submits lists as free text (one item per line or comma separated).
  defp normalize_lists(attrs) do
    attrs
    |> normalize_list("allowed_hosts", &normalize_host/1)
    |> normalize_list("allowed_chat_ids", &String.trim/1)
  end

  defp normalize_list(attrs, key, fun) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        items =
          value
          |> String.split([",", "\n", " ", "\t", "\r"], trim: true)
          |> Enum.map(fun)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        Map.put(attrs, key, items)

      _ ->
        attrs
    end
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.replace(~r{[/?#].*$}, "")
    |> String.replace_prefix("www.", "")
    |> String.trim_trailing(".")
    # Links are matched by their ASCII (Punycode) host, see Angler.Links.host/1.
    |> Angler.Links.IDN.to_ascii()
  end

  defp validate_hosts(changeset) do
    validate_change(changeset, :allowed_hosts, fn :allowed_hosts, hosts ->
      case Enum.reject(hosts, &Regex.match?(~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/, &1)) do
        [] -> []
        invalid -> [allowed_hosts: "contains invalid hosts: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  # Telegram chat ids have at most 52 significant bits; bigger numbers don't fit the
  # database column either.
  defp validate_chat_ids(changeset) do
    validate_change(changeset, :allowed_chat_ids, fn :allowed_chat_ids, ids ->
      case Enum.reject(ids, &(abs(&1) < @max_chat_id)) do
        [] -> []
        invalid -> [allowed_chat_ids: "contains invalid chat ids: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  defp put_default_lists(changeset) do
    Enum.reduce([:allowed_hosts, :allowed_chat_ids], changeset, fn field, changeset ->
      if get_field(changeset, field) == nil, do: put_change(changeset, field, []), else: changeset
    end)
  end
end
