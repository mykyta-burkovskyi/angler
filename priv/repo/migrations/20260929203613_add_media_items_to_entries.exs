defmodule Angler.Repo.Migrations.AddMediaItemsToEntries do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      # The photos and videos of an album entry (media_kind "album") in display
      # order, see Angler.Entries.MediaItem; empty for everything else.
      add :media_items, {:array, :map}, null: false, default: []
    end
  end
end
