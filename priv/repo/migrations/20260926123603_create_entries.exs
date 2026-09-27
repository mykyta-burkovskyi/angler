defmodule Angler.Repo.Migrations.CreateEntries do
  use Ecto.Migration

  def change do
    create table(:entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Processing state machine, see Angler.Entries.Entry
      add :status, :string, null: false, default: "queued"
      add :stage_detail, :string

      # What to fetch
      add :url, :text, null: false
      add :source_host, :string

      # Where the link came from / where the reply goes
      add :update_id, :bigint
      add :chat_id, :bigint, null: false
      add :chat_type, :string, null: false
      add :chat_title, :string
      add :message_id, :bigint, null: false
      add :message_thread_id, :bigint
      add :from_id, :bigint
      add :from_name, :string

      # Scheduling / retries
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :available_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :claimed_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :error, :text
      add :error_kind, :string

      # Media metadata
      add :title, :text
      add :extractor, :string
      add :duration, :float
      add :width, :integer
      add :height, :integer
      add :video_codec, :string
      add :source_bytes, :bigint
      add :output_bytes, :bigint
      add :transcoded, :boolean, null: false, default: false

      # Local storage accounting
      add :storage_path, :text
      add :stored_bytes, :bigint, null: false, default: 0
      add :purged_at, :utc_datetime_usec

      # Telegram delivery result
      add :telegram_file_id, :text
      add :telegram_file_unique_id, :string
      add :reply_message_id, :bigint
      add :reused_file_id, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    # Telegram may deliver the same update more than once.
    create unique_index(:entries, [:chat_id, :message_id, :url])

    # Producer claim query: WHERE status = 'queued' AND available_at <= now() ORDER BY available_at
    create index(:entries, [:available_at],
             where: "status = 'queued'",
             name: :entries_queued_index
           )

    # Dashboard listing (newest first) and status filters
    create index(:entries, [:inserted_at])
    create index(:entries, [:status, :inserted_at])

    # Reusing an already uploaded Telegram file for the same URL
    create index(:entries, [:url, :finished_at],
             where: "telegram_file_id IS NOT NULL",
             name: :entries_file_id_cache_index
           )

    # Storage eviction: oldest finished entries that still hold files
    create index(:entries, [:finished_at], where: "stored_bytes > 0", name: :entries_stored_index)
  end
end
