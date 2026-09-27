defmodule Angler.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    # A single-row table holding the settings that are adjustable from the dashboard.
    create table(:settings, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1

      add :storage_limit_mb, :integer, null: false, default: 10_240
      add :retention_hours, :integer, null: false, default: 168
      add :max_source_mb, :integer, null: false, default: 1024
      add :max_duration_minutes, :integer, null: false, default: 30
      add :upload_limit_mb, :integer
      add :allowed_hosts, {:array, :string}, null: false, default: []
      add :allowed_chat_ids, {:array, :bigint}, null: false, default: []
      add :failure_replies, :string, null: false, default: "private"
      add :reactions_enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:settings, :single_row, check: "id = 1")
  end
end
