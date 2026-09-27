defmodule Angler.Repo.Migrations.AddHistoryDaysToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Finished entries are deleted this many days after they finished (0 = never).
      add :history_days, :integer, null: false, default: 90
    end
  end
end
