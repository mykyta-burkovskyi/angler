defmodule Angler.Settings do
  @moduledoc """
  Dashboard-adjustable runtime settings (storage limits, source limits, filters).

  Settings are read from the database on every call (a primary key lookup), so
  changes apply immediately to new work. Updates are broadcast on the
  `"settings"` topic as `{:settings_updated, %Setting{}}`.
  """
  alias Angler.Repo
  alias Angler.Settings.Setting

  @pubsub Angler.PubSub
  @topic "settings"
  @mb 1_000_000

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Returns the current settings (defaults if never saved)."
  @spec get() :: Setting.t()
  def get, do: Repo.get(Setting, 1) || %Setting{id: 1}

  @doc "Returns a changeset for the dashboard settings form."
  def change(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs, max_upload_mb())
  end

  @doc "Validates and saves settings, broadcasting the new value."
  @spec update(map()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def update(attrs) do
    changeset = change(get(), attrs)

    with {:ok, setting} <-
           Repo.insert_or_update(changeset,
             on_conflict: {:replace_all_except, [:id, :inserted_at]},
             conflict_target: :id
           ) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:settings_updated, setting})
      {:ok, setting}
    end
  end

  @doc """
  The largest upload the configured Bot API server accepts, in MB:
  50 for api.telegram.org, 2000 for a local Bot API server.
  """
  @spec max_upload_mb() :: pos_integer()
  def max_upload_mb do
    if Angler.Telegram.Config.local_mode?(), do: 2000, else: 50
  end

  @doc "Upload size limit in bytes that produced videos must fit into."
  @spec upload_limit_bytes(Setting.t()) :: pos_integer()
  def upload_limit_bytes(%Setting{upload_limit_mb: mb}) do
    min(mb || max_upload_mb(), max_upload_mb()) * @mb
  end

  @spec storage_limit_bytes(Setting.t()) :: pos_integer()
  def storage_limit_bytes(%Setting{storage_limit_mb: mb}), do: mb * @mb

  @spec max_source_bytes(Setting.t()) :: pos_integer()
  def max_source_bytes(%Setting{max_source_mb: mb}), do: mb * @mb

  @spec max_duration_seconds(Setting.t()) :: pos_integer()
  def max_duration_seconds(%Setting{max_duration_minutes: minutes}), do: minutes * 60

  @doc "Whether links from this chat should be processed."
  @spec chat_allowed?(Setting.t(), integer()) :: boolean()
  def chat_allowed?(%Setting{allowed_chat_ids: []}, _chat_id), do: true
  def chat_allowed?(%Setting{allowed_chat_ids: ids}, chat_id), do: chat_id in ids

  @doc """
  Whether a link to `host` should be processed. Matches the host itself and its
  subdomains, ignoring a leading `www.`.
  """
  @spec host_allowed?(Setting.t(), String.t() | nil) :: boolean()
  def host_allowed?(%Setting{allowed_hosts: []}, _host), do: true
  def host_allowed?(%Setting{}, nil), do: false

  def host_allowed?(%Setting{allowed_hosts: hosts}, host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    Enum.any?(hosts, fn allowed -> host == allowed or String.ends_with?(host, "." <> allowed) end)
  end
end
