defmodule Angler.Repo.Migrations.AddTitleCaptionsToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Videos are posted with their title as the caption.
      add :title_captions, :boolean, null: false, default: true
    end
  end
end
